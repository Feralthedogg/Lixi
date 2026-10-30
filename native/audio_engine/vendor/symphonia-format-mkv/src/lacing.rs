// Symphonia
// Copyright (c) 2019-2022 The Project Symphonia Developers.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use std::collections::{HashMap, VecDeque};
use std::convert::TryFrom;

use symphonia_core::errors::{decode_error, Result};
use symphonia_core::io::{BufReader, ReadBytes};

use crate::demuxer::TrackState;
use crate::ebml::{read_signed_vint, read_unsigned_vint};

enum Lacing {
    None,
    Xiph,
    FixedSize,
    Ebml,
}

fn parse_flags(flags: u8) -> Result<Lacing> {
    match (flags >> 1) & 0b11 {
        0b00 => Ok(Lacing::None),
        0b01 => Ok(Lacing::Xiph),
        0b10 => Ok(Lacing::FixedSize),
        0b11 => Ok(Lacing::Ebml),
        _ => unreachable!(),
    }
}

fn read_ebml_sizes<R: ReadBytes>(mut reader: R, frames: usize) -> Result<Vec<u64>> {
    let mut sizes: Vec<u64> = Vec::new();
    for _ in 0..frames {
        if let Some(last_size) = sizes.last().copied() {
            let delta = read_signed_vint(&mut reader)?;
            sizes.push(last_size.checked_add_signed(delta).ok_or(
                symphonia_core::errors::Error::DecodeError("mkv: invalid lace size"),
            )?)
        } else {
            let size = read_unsigned_vint(&mut reader)?;
            sizes.push(size);
        }
    }

    Ok(sizes)
}

pub(crate) fn read_xiph_sizes<R: ReadBytes>(mut reader: R, frames: usize) -> Result<Vec<u64>> {
    let mut prefixes = 0;
    let mut sizes = Vec::new();
    while sizes.len() < frames {
        let byte = reader.read_byte()? as u64;
        if byte == 255 {
            prefixes += 1;
        } else {
            let size = prefixes * 255 + byte;
            prefixes = 0;
            sizes.push(size);
        }
    }

    Ok(sizes)
}

pub(crate) struct Frame {
    pub(crate) track: u32,
    /// Absolute frame timestamp.
    pub(crate) timestamp: u64,
    pub(crate) duration: u64,
    pub(crate) data: Box<[u8]>,
    pub(crate) trim_start: u32,
    pub(crate) trim_end: u32,
}

pub(crate) fn calc_abs_block_timestamp(cluster_ts: u64, rel_block_ts: i16) -> u64 {
    (i128::from(cluster_ts) + i128::from(rel_block_ts)).clamp(0, i128::from(u64::MAX)) as u64
}

pub(crate) fn extract_frames(
    block: &[u8],
    block_duration: Option<u64>,
    discard_padding: i64,
    tracks: &mut HashMap<u32, TrackState>,
    cluster_timestamp: u64,
    timestamp_scale: u64,
    buffer: &mut VecDeque<Frame>,
) -> Result<()> {
    let first_frame = buffer.len();
    let mut reader = BufReader::new(block);
    let track = read_unsigned_vint(&mut reader)? as u32;
    let rel_ts = reader.read_be_u16()? as i16;
    let flags = reader.read_byte()?;
    let lacing = parse_flags(flags)?;

    let default_frame_duration = tracks
        .get(&track)
        .and_then(|it| it.default_frame_duration)
        .map(|it| it / timestamp_scale);

    let mut timestamp = calc_abs_block_timestamp(cluster_timestamp, rel_ts);

    match lacing {
        Lacing::None => {
            let data = reader.read_boxed_slice_exact(block.len() - reader.pos() as usize)?;
            let duration = block_duration.or(default_frame_duration).unwrap_or(0);
            buffer.push_back(Frame {
                track,
                timestamp,
                data,
                duration,
                trim_start: 0,
                trim_end: 0,
            });
        }
        Lacing::Xiph | Lacing::Ebml => {
            // Read number of stored sizes which is actually `number of frames` - 1
            // since size of the last frame is deduced from block size.
            let frames = reader.read_byte()? as usize;
            let sizes = match lacing {
                Lacing::Xiph => read_xiph_sizes(&mut reader, frames)?,
                Lacing::Ebml => read_ebml_sizes(&mut reader, frames)?,
                _ => unreachable!(),
            };

            let frame_duration = block_duration
                .map(|it| it / (frames + 1) as u64)
                .or(default_frame_duration)
                .unwrap_or(0);

            for frame_size in sizes {
                let frame_size = usize::try_from(frame_size).map_err(|_| {
                    symphonia_core::errors::Error::DecodeError("mkv: lace size overflow")
                })?;
                if frame_size > block.len().saturating_sub(reader.pos() as usize) {
                    return decode_error("mkv: lace size exceeds block");
                }
                let data = reader.read_boxed_slice_exact(frame_size)?;
                buffer.push_back(Frame {
                    track,
                    timestamp,
                    data,
                    duration: frame_duration,
                    trim_start: 0,
                    trim_end: 0,
                });
                timestamp = timestamp.saturating_add(frame_duration);
            }

            // Size of last frame is not provided so we read to the end of the block.
            let size = block.len() - reader.pos() as usize;
            let data = reader.read_boxed_slice_exact(size)?;
            buffer.push_back(Frame {
                track,
                timestamp,
                data,
                duration: frame_duration,
                trim_start: 0,
                trim_end: 0,
            });
        }
        Lacing::FixedSize => {
            let frames = reader.read_byte()? as usize + 1;
            let total_size = block.len() - reader.pos() as usize;
            if !total_size.is_multiple_of(frames) {
                return decode_error("mkv: invalid block size");
            }

            let frame_duration = block_duration
                .map(|it| it / frames as u64)
                .or(default_frame_duration)
                .unwrap_or(0);

            let frame_size = total_size / frames;
            for _ in 0..frames {
                let data = reader.read_boxed_slice_exact(frame_size)?;
                buffer.push_back(Frame {
                    track,
                    timestamp,
                    data,
                    duration: frame_duration,
                    trim_start: 0,
                    trim_end: 0,
                });
                timestamp = timestamp.saturating_add(frame_duration);
            }
        }
    }

    if let Some(state) = tracks.get_mut(&track) {
        if state.codec_params.codec == symphonia_core::codecs::CODEC_TYPE_OPUS {
            let frames = buffer.iter_mut().skip(first_frame).collect::<Vec<_>>();
            let raw_tick = i128::from(cluster_timestamp) + i128::from(rel_ts);
            let first_tick = *state.opus_first_tick.get_or_insert(raw_tick);
            let observed = (raw_tick - first_tick) * i128::from(timestamp_scale) * 48_000;
            let expected = i128::from(state.opus_raw_samples) * 1_000_000_000;
            if (observed - expected).abs() > i128::from(timestamp_scale) * 48_000 + 1_000_000_000 {
                return decode_error("mkv: discontinuous Opus timestamps unsupported");
            }
            normalize_opus(frames, state, discard_padding)?;
        }
    }
    Ok(())
}

// Opus packets carry exact durations; Matroska timestamps may only have 1 ms
// precision. Dense audio is counted in decoded samples, without rounding PTS.
fn normalize_opus(
    mut frames: Vec<&mut Frame>,
    state: &mut TrackState,
    padding_ns: i64,
) -> Result<()> {
    for frame in &mut frames {
        frame.duration = opus::packet::get_nb_samples(&frame.data, 48_000)
            .map_err(|_| symphonia_core::errors::Error::DecodeError("mkv: invalid Opus packet"))?
            as u64;
    }
    for frame in &frames {
        state.opus_raw_samples = state.opus_raw_samples.checked_add(frame.duration).ok_or(
            symphonia_core::errors::Error::DecodeError("mkv: duration overflow"),
        )?;
    }
    let mut padding =
        ((u128::from(padding_ns.unsigned_abs()) * 48_000 + 500_000_000) / 1_000_000_000) as u64;
    if padding_ns >= 0 {
        for frame in frames.iter_mut().rev() {
            frame.trim_end = padding.min(frame.duration) as u32;
            padding -= u64::from(frame.trim_end);
        }
    } else {
        for frame in &mut frames {
            frame.trim_start = padding.min(frame.duration) as u32;
            padding -= u64::from(frame.trim_start);
        }
    }
    if padding != 0 {
        return decode_error("mkv: padding exceeds block duration");
    }
    for frame in frames {
        let available = frame.duration - u64::from(frame.trim_start + frame.trim_end);
        let delay = state.opus_skip.min(available);
        frame.trim_start += delay as u32;
        state.opus_skip -= delay;
        frame.duration -= u64::from(frame.trim_start + frame.trim_end);
        frame.timestamp = state.opus_position;
        state.opus_position = state.opus_position.checked_add(frame.duration).ok_or(
            symphonia_core::errors::Error::DecodeError("mkv: duration overflow"),
        )?;
    }
    Ok(())
}
