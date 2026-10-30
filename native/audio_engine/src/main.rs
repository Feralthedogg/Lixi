mod dsp;
mod opus_decoder;
mod pcm;
mod protocol;
mod source;
mod timescale;

use opus::{Application, Channels, Encoder};
use rubato::{FftFixedInOut, Resampler};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Condvar, Mutex,
};
use symphonia::core::{
    codecs::{Decoder, DecoderOptions, CODEC_TYPE_OPUS},
    errors::Error,
    formats::{FormatOptions, SeekMode, SeekTo},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::Time,
};

#[derive(Deserialize)]
struct Open {
    length: u64,
    extension: String,
    #[serde(default)]
    position: u64,
    #[serde(default)]
    end_time: Option<u64>,
    #[serde(default = "unity")]
    gain: f32,
    #[serde(default)]
    filters: Value,
}
fn unity() -> f32 {
    1.0
}

struct Control {
    limit: u64,
    emitted: u64,
    gain: f32,
}
type Shared = Arc<(Mutex<Control>, Condvar)>;

struct RateConverter {
    engine: FftFixedInOut<f32>,
    input: Vec<Vec<f32>>,
    output: Vec<Vec<f32>>,
    delay: usize,
}
impl RateConverter {
    fn new(rate: u32) -> Result<Self, rubato::ResamplerConstructionError> {
        let engine = FftFixedInOut::<f32>::new(rate as usize, 48_000, 1024, 2)?;
        let input = engine.input_buffer_allocate(true);
        let output = engine.output_buffer_allocate(true);
        let delay = engine.output_delay();
        Ok(Self {
            engine,
            input,
            output,
            delay,
        })
    }
}

fn run(
    open: Open,
    wire: protocol::Wire,
    responses: mpsc::Receiver<(u64, Vec<u8>)>,
    running: Arc<AtomicBool>,
    control: Shared,
) -> Result<(), Box<dyn std::error::Error>> {
    let source = source::Source::new(open.length, wire.clone(), responses, running.clone());
    let stream = MediaSourceStream::new(Box::new(source), Default::default());
    let mut hint = Hint::new();
    hint.with_extension(&open.extension);
    let probed = symphonia::default::get_probe().format(
        &hint,
        stream,
        &FormatOptions::default(),
        &MetadataOptions {
            limit_metadata_bytes: symphonia::core::meta::Limit::Maximum(1_048_576),
            ..Default::default()
        },
    )?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|track| {
            track.codec_params.sample_rate.is_some() && track.codec_params.channels.is_some()
        })
        .ok_or("no audio track")?;
    let track_id = track.id;
    let rate = track
        .codec_params
        .sample_rate
        .ok_or("unknown sample rate")?;
    let channels = track
        .codec_params
        .channels
        .ok_or("unknown channel layout")?
        .count();
    if !(8_000..=192_000).contains(&rate) || !(1..=2).contains(&channels) {
        return Err("unsupported audio layout".into());
    }
    let length_ms = if track.codec_params.codec == CODEC_TYPE_OPUS {
        track.codec_params.n_frames.unwrap_or(0).div_ceil(48)
    } else {
        track.codec_params.n_frames.map_or(0, |n| {
            let time = track
                .codec_params
                .time_base
                .unwrap_or(symphonia::core::units::TimeBase::new(1, rate))
                .calc_time(n);
            time.seconds * 1000 + (time.frac * 1000.).round() as u64
        })
    };
    let opus_samples = if track.codec_params.codec == CODEC_TYPE_OPUS {
        track.codec_params.n_frames
    } else {
        None
    };
    let timebase = track.codec_params.time_base;
    let mut decoder: Box<dyn Decoder> = if track.codec_params.codec == CODEC_TYPE_OPUS {
        Box::new(opus_decoder::OpusDecoder::try_new(
            &track.codec_params,
            &DecoderOptions::default(),
        )?)
    } else {
        symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?
    };
    wire.send(
        2,
        0,
        &serde_json::to_vec(
            &json!({"length": length_ms, "sampleRate": rate, "channels": channels}),
        )?,
    )?;
    let mut skip_samples = 0;
    if open.position > 0 {
        let seek = format.seek(
            SeekMode::Accurate,
            SeekTo::Time {
                time: Time::new(open.position / 1000, (open.position % 1000) as f64 / 1000.),
                track_id: Some(track_id),
            },
        )?;
        decoder.reset();
        if let Some(tb) = timebase {
            let actual = tb.calc_time(seek.actual_ts);
            let actual_samples =
                actual.seconds * u64::from(rate) + (actual.frac * f64::from(rate)).round() as u64;
            skip_samples =
                (open.position * u64::from(rate) / 1000).saturating_sub(actual_samples) as usize;
        }
    }
    let mut encoder = Encoder::new(48_000, Channels::Stereo, Application::Audio)?;
    encoder.set_bitrate(opus::Bitrate::Bits(96_000))?;
    let mut resampler = if rate != 48_000 {
        Some(RateConverter::new(rate)?)
    } else {
        None
    };
    let mut decoded = pcm::StereoInput::new(rate, channels);
    let mut input: [VecDeque<f32>; 2] = [VecDeque::new(), VecDeque::new()];
    let mut output: VecDeque<[f32; 2]> = VecDeque::with_capacity(1920);
    let mut eof = false;
    let mut emitted_samples = 0_u64;
    let end_ms = open.end_time.map_or(length_ms, |end| {
        if length_ms > 0 {
            end.min(length_ms)
        } else {
            end
        }
    });
    let mut timescale = timescale::Timescale::new(&open.filters);
    let expected_samples = if let Some(total) = opus_samples {
        let end = open
            .end_time
            .map_or(total, |end| total.min(end.saturating_mul(48)));
        Some(
            (end.saturating_sub(open.position.saturating_mul(48)) as f64 / timescale.speed).round()
                as u64,
        )
    } else if end_ms > 0 {
        Some((end_ms.saturating_sub(open.position) as f64 * 48. / timescale.speed).round() as u64)
    } else {
        None
    };
    let mut dsp = dsp::Dsp::new(open.filters);

    while running.load(Ordering::Acquire) {
        let gain = {
            let (lock, wake) = &*control;
            let mut state = lock.lock().map_err(|_| "control lock poisoned")?;
            while state.emitted >= state.limit && running.load(Ordering::Acquire) {
                state = wake.wait(state).map_err(|_| "control lock poisoned")?;
            }
            state.gain
        };
        if !running.load(Ordering::Acquire) {
            break;
        }
        if expected_samples.is_some_and(|n| emitted_samples >= n) {
            wire.send(6, 0, &[])?;
            break;
        }
        while output.len() < 960 && !eof {
            match format.next_packet() {
                Ok(packet) if packet.track_id() == track_id => {
                    let audio = decoder.decode(&packet)?;
                    let frames = decoded.frames(audio, &mut skip_samples)?;
                    if resampler.is_none() {
                        timescale.feed(frames, &mut output)?;
                    } else {
                        for frame in frames {
                            input[0].push_back(frame[0]);
                            input[1].push_back(frame[1]);
                        }
                    }
                }
                Ok(_) => continue,
                Err(Error::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => {
                    eof = true
                }
                Err(err) => return Err(err.into()),
            }
            if let Some(resampler) = &mut resampler {
                let needed = resampler.engine.input_frames_next();
                while input[0].len() >= needed || (eof && !input[0].is_empty()) {
                    for (channel, block) in resampler.input.iter_mut().enumerate() {
                        for sample in &mut block[..needed] {
                            *sample = input[channel].pop_front().unwrap_or(0.);
                        }
                    }
                    let (_, written) = resampler.engine.process_into_buffer(
                        &resampler.input,
                        &mut resampler.output,
                        None,
                    )?;
                    let delay = &mut resampler.delay;
                    let converted = &resampler.output;
                    let frames = converted[0][..written]
                        .iter()
                        .zip(&converted[1][..written])
                        .filter_map(|(&left, &right)| {
                            if *delay > 0 {
                                *delay -= 1;
                                None
                            } else {
                                Some([left, right])
                            }
                        });
                    timescale.feed(frames, &mut output)?;
                }
                if eof
                    && expected_samples.is_some_and(|n| emitted_samples + (output.len() as u64) < n)
                {
                    for block in &mut resampler.input {
                        block.fill(0.);
                    }
                    let (_, written) = resampler.engine.process_into_buffer(
                        &resampler.input,
                        &mut resampler.output,
                        None,
                    )?;
                    let converted = &resampler.output;
                    timescale.feed(
                        converted[0][..written]
                            .iter()
                            .zip(&converted[1][..written])
                            .map(|(&left, &right)| [left, right]),
                        &mut output,
                    )?;
                }
            }
            if eof {
                timescale.flush(&mut output)?;
            }
        }
        let available = expected_samples.map_or(output.len(), |n| {
            output.len().min(n.saturating_sub(emitted_samples) as usize)
        });
        if available == 0 && eof {
            wire.send(6, 0, &[])?;
            break;
        }
        let valid = available.min(960);
        let mut pcm = [0.; 1920];
        for frame in pcm[..valid * 2].chunks_exact_mut(2) {
            let mut sample = output.pop_front().ok_or("PCM buffer invariant")?;
            dsp.process(&mut sample, gain);
            frame.copy_from_slice(&sample);
        }
        let mut payload = [0; 1034];
        let bytes = encoder.encode_float(&pcm, &mut payload[10..])?;
        emitted_samples += valid as u64;
        let position = (open.position
            + (emitted_samples as f64 * timescale.speed / 48.).round() as u64)
            .min(if end_ms > 0 { end_ms } else { u64::MAX });
        payload[..8].copy_from_slice(&position.to_be_bytes());
        payload[8..10].copy_from_slice(&(valid as u16).to_be_bytes());
        wire.send(5, 0, &payload[..10 + bytes])?;
        control
            .0
            .lock()
            .map_err(|_| "control lock poisoned")?
            .emitted += 1;
    }
    Ok(())
}

fn main() {
    if let Err(error) = main_result() {
        eprintln!("lixi-audio: {error}");
        std::process::exit(1);
    }
}
fn main_result() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = io::stdin().lock();
    let first = protocol::read_packet(&mut input)?;
    if first[1] != 1 {
        return Err("OPEN required".into());
    }
    let context: [u8; 40] = first[4..44].try_into()?;
    let wire = protocol::Wire::new(context);
    let open: Open = serde_json::from_slice(&first[44..])?;
    let running = Arc::new(AtomicBool::new(true));
    let control = Arc::new((
        Mutex::new(Control {
            limit: 0,
            emitted: 0,
            gain: open.gain,
        }),
        Condvar::new(),
    ));
    let (responses, received) = mpsc::sync_channel(1);
    let engine_control = control.clone();
    let engine_running = running.clone();
    let engine_wire = wire.clone();
    let engine = std::thread::spawn(move || {
        if let Err(err) = run(
            open,
            engine_wire.clone(),
            received,
            engine_running,
            engine_control,
        ) {
            let message = err.to_string();
            let _ = engine_wire.send(
                9,
                0,
                &serde_json::to_vec(&json!({"message": message})).unwrap_or_default(),
            );
        }
    });
    while let Ok(packet) = protocol::read_packet(&mut input) {
        if packet[4..36] != context[..32] {
            break;
        }
        match packet[1] {
            4 => {
                let request = u64::from_be_bytes(packet[36..44].try_into()?);
                if packet.len() > 65_536 + 44 || responses.send((request, packet)).is_err() {
                    break;
                }
            }
            7 if packet.len() == 52 => {
                let limit = u64::from_be_bytes(packet[44..52].try_into()?);
                let mut state = control.0.lock().map_err(|_| "control lock poisoned")?;
                if limit < state.limit || limit > state.emitted + 25 {
                    break;
                }
                state.limit = limit;
                control.1.notify_one();
            }
            10 if packet.len() == 48 => {
                let gain = f32::from_be_bytes(packet[44..48].try_into()?);
                if !gain.is_finite() || !(0.0..=50.0).contains(&gain) {
                    break;
                }
                control.0.lock().map_err(|_| "control lock poisoned")?.gain = gain;
            }
            _ => break,
        }
    }
    running.store(false, Ordering::Release);
    control.1.notify_one();
    drop(responses);
    engine.join().map_err(|_| "engine panicked")?;
    Ok(())
}
