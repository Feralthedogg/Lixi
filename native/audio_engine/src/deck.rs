use crate::{opus_decoder, pcm, source, timescale, Open, RateConverter};
use rubato::Resampler;
use serde_json::{json, Value};
use std::{collections::VecDeque, io};
use symphonia::core::{
    codecs::{Decoder, DecoderOptions, CODEC_TYPE_OPUS},
    errors::Error,
    formats::{FormatOptions, FormatReader, SeekMode, SeekTo},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::Time,
};

pub type AudioError = Box<dyn std::error::Error + Send + Sync>;

pub struct PcmFrame {
    pub samples: [f32; 1920],
    pub valid: usize,
    pub position: u64,
    pub source_start_ms: f64,
    pub source_step_ms: f64,
}

pub struct Deck {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    pub rate: u32,
    pub channels: usize,
    pub length_ms: u64,
    start_position: u64,
    skip_samples: usize,
    resampler: Option<RateConverter>,
    decoded: pcm::StereoInput,
    input: [VecDeque<f32>; 2],
    output: VecDeque<[f32; 2]>,
    eof: bool,
    pub emitted_samples: u64,
    end_ms: u64,
    pub timescale: timescale::Timescale,
    expected_samples: Option<u64>,
    dynamic_tempo: bool,
    media_samples: f64,
}

impl Deck {
    pub fn open(open: &Open, source: source::Source) -> Result<Self, AudioError> {
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
            symphonia::default::get_codecs()
                .make(&track.codec_params, &DecoderOptions::default())?
        };
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
                let actual_samples = actual.seconds * u64::from(rate)
                    + (actual.frac * f64::from(rate)).round() as u64;
                skip_samples = (open.position * u64::from(rate) / 1000)
                    .saturating_sub(actual_samples) as usize;
            }
        }
        let resampler = if rate != 48_000 {
            Some(RateConverter::new(rate)?)
        } else {
            None
        };
        let decoded = pcm::StereoInput::new(rate, channels);
        let input: [VecDeque<f32>; 2] = [VecDeque::new(), VecDeque::new()];
        let output: VecDeque<[f32; 2]> = VecDeque::with_capacity(1920);
        let eof = false;
        let emitted_samples = 0_u64;
        let end_ms = open.end_time.map_or(length_ms, |end| {
            if length_ms > 0 {
                end.min(length_ms)
            } else {
                end
            }
        });
        let mut timescale = timescale::Timescale::new(&open.filters);
        if open.tempo_multiplier != 1. {
            timescale.set_multiplier(open.tempo_multiplier)?;
        }
        let expected_samples = if let Some(total) = opus_samples {
            let end = open
                .end_time
                .map_or(total, |end| total.min(end.saturating_mul(48)));
            Some(
                (end.saturating_sub(open.position.saturating_mul(48)) as f64 / timescale.speed)
                    .round() as u64,
            )
        } else if end_ms > 0 {
            Some(
                (end_ms.saturating_sub(open.position) as f64 * 48. / timescale.speed).round()
                    as u64,
            )
        } else {
            None
        };
        Ok(Self {
            format,
            decoder,
            track_id,
            rate,
            channels,
            length_ms,
            start_position: open.position,
            skip_samples,
            resampler,
            decoded,
            input,
            output,
            eof,
            emitted_samples,
            end_ms,
            timescale,
            expected_samples,
            dynamic_tempo: false,
            media_samples: open.position as f64 * 48.,
        })
    }

    pub fn metadata(&self) -> Value {
        json!({"length": self.length_ms, "sampleRate": self.rate, "channels": self.channels})
    }

    pub fn end_ms(&self) -> u64 {
        self.end_ms
    }

    pub fn set_multiplier(&mut self, multiplier: f64) -> Result<(), AudioError> {
        if !self.dynamic_tempo {
            self.media_samples = self.start_position as f64 * 48.
                + self.emitted_samples as f64 * self.timescale.speed;
        }
        self.timescale.set_multiplier(multiplier)?;
        if self.emitted_samples > 0 {
            self.dynamic_tempo = true;
            self.expected_samples = None;
        }
        Ok(())
    }

    pub fn frame(&mut self) -> Result<Option<PcmFrame>, AudioError> {
        if self
            .expected_samples
            .is_some_and(|n| self.emitted_samples >= n)
        {
            return Ok(None);
        }
        while self.output.len() < 960 && !self.eof {
            match self.format.next_packet() {
                Ok(packet) if packet.track_id() == self.track_id => {
                    let audio = self.decoder.decode(&packet)?;
                    let frames = self.decoded.frames(audio, &mut self.skip_samples)?;
                    if self.resampler.is_none() {
                        self.timescale.feed(frames, &mut self.output)?;
                    } else {
                        for frame in frames {
                            self.input[0].push_back(frame[0]);
                            self.input[1].push_back(frame[1]);
                        }
                    }
                }
                Ok(_) => continue,
                Err(Error::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => {
                    self.eof = true
                }
                Err(err) => return Err(err.into()),
            }
            if let Some(resampler) = &mut self.resampler {
                let needed = resampler.engine.input_frames_next();
                while self.input[0].len() >= needed || (self.eof && !self.input[0].is_empty()) {
                    for (channel, block) in resampler.input.iter_mut().enumerate() {
                        for sample in &mut block[..needed] {
                            *sample = self.input[channel].pop_front().unwrap_or(0.);
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
                    self.timescale.feed(frames, &mut self.output)?;
                }
                if self.eof
                    && self
                        .expected_samples
                        .is_some_and(|n| self.emitted_samples + (self.output.len() as u64) < n)
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
                    self.timescale.feed(
                        converted[0][..written]
                            .iter()
                            .zip(&converted[1][..written])
                            .map(|(&left, &right)| [left, right]),
                        &mut self.output,
                    )?;
                }
            }
            if self.eof {
                self.timescale.flush(&mut self.output)?;
            }
        }
        let available = self.expected_samples.map_or(self.output.len(), |n| {
            self.output
                .len()
                .min(n.saturating_sub(self.emitted_samples) as usize)
        });
        if available == 0 && self.eof {
            return Ok(None);
        }
        let valid = available.min(960);
        let mut samples = [0.; 1920];
        for frame in samples[..valid * 2].chunks_exact_mut(2) {
            frame.copy_from_slice(&self.output.pop_front().ok_or("PCM buffer invariant")?);
        }
        let source_start_ms = if self.dynamic_tempo {
            self.media_samples / 48.
        } else {
            self.start_position as f64 + self.emitted_samples as f64 * self.timescale.speed / 48.
        };
        let source_step_ms = self.timescale.speed / 48.;
        self.emitted_samples += valid as u64;
        self.media_samples += valid as f64 * self.timescale.speed;
        let position = if self.dynamic_tempo {
            (self.media_samples / 48.).round() as u64
        } else {
            self.start_position
                + (self.emitted_samples as f64 * self.timescale.speed / 48.).round() as u64
        };
        let position = position.min(if self.end_ms > 0 {
            self.end_ms
        } else {
            u64::MAX
        });
        Ok(Some(PcmFrame {
            samples,
            valid,
            position,
            source_start_ms,
            source_step_ms,
        }))
    }
}
