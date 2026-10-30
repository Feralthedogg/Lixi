mod dsp;
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
    audio::SampleBuffer,
    codecs::DecoderOptions,
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
    let track = format.default_track().ok_or("no audio track")?;
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
    let length_ms = track
        .codec_params
        .n_frames
        .map_or(0, |n| n * 1000 / u64::from(rate));
    let timebase = track.codec_params.time_base;
    let mut decoder =
        symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?;
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
        Some(FftFixedInOut::<f32>::new(rate as usize, 48_000, 1024, 2)?)
    } else {
        None
    };
    let mut delay = resampler.as_ref().map_or(0, Resampler::output_delay);
    let mut input: [VecDeque<f32>; 2] = [VecDeque::new(), VecDeque::new()];
    let mut output: VecDeque<[f32; 2]> = VecDeque::new();
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
    let expected_samples = if end_ms > 0 {
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
                    let mut samples =
                        SampleBuffer::<f32>::new(audio.capacity() as u64, *audio.spec());
                    samples.copy_interleaved_ref(audio);
                    for frame in samples.samples().chunks_exact(channels) {
                        if skip_samples > 0 {
                            skip_samples -= 1;
                            continue;
                        }
                        input[0].push_back(frame[0]);
                        input[1].push_back(frame[channels - 1]);
                    }
                }
                Ok(_) => continue,
                Err(Error::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => {
                    eof = true
                }
                Err(err) => return Err(err.into()),
            }
            if let Some(resampler) = &mut resampler {
                let needed = resampler.input_frames_next();
                while input[0].len() >= needed || (eof && !input[0].is_empty()) {
                    let mut block = [Vec::with_capacity(needed), Vec::with_capacity(needed)];
                    for channel in 0..2 {
                        for _ in 0..needed {
                            block[channel].push(input[channel].pop_front().unwrap_or(0.));
                        }
                    }
                    let converted = resampler.process(&block, None)?;
                    let frames =
                        converted[0]
                            .iter()
                            .zip(&converted[1])
                            .filter_map(|(&left, &right)| {
                                if delay > 0 {
                                    delay -= 1;
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
                    let converted = resampler.process_partial::<Vec<f32>>(None, None)?;
                    timescale.feed(
                        converted[0]
                            .iter()
                            .zip(&converted[1])
                            .map(|(&left, &right)| [left, right]),
                        &mut output,
                    )?;
                }
            } else {
                let [left, right] = &mut input;
                timescale.feed(
                    left.drain(..).zip(right.drain(..)).map(|(l, r)| [l, r]),
                    &mut output,
                )?;
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
        let mut opus = [0; 1024];
        let bytes = encoder.encode_float(&pcm, &mut opus)?;
        emitted_samples += valid as u64;
        let position = (open.position
            + (emitted_samples as f64 * timescale.speed / 48.).round() as u64)
            .min(if end_ms > 0 { end_ms } else { u64::MAX });
        let mut payload = Vec::with_capacity(10 + bytes);
        payload.extend_from_slice(&position.to_be_bytes());
        payload.extend_from_slice(&(valid as u16).to_be_bytes());
        payload.extend_from_slice(&opus[..bytes]);
        wire.send(5, 0, &payload)?;
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
                if packet.len() > 65_536 + 44
                    || responses.send((request, packet[44..].to_vec())).is_err()
                {
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
