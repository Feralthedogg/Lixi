use std::{borrow::Cow, iter::Zip, slice};
use symphonia::core::{
    audio::{AudioBufferRef, SampleBuffer, Signal},
    errors::{decode_error, Result},
};

/// Borrows the decoder's valid planes, or a reusable conversion scratch buffer.
/// The iterator is consumed before the next decode; it never retains audio.
pub struct StereoInput {
    rate: u32,
    channels: usize,
    scratch: Option<SampleBuffer<f32>>,
}

pub enum Frames<'a> {
    Planar(Zip<slice::Iter<'a, f32>, slice::Iter<'a, f32>>),
    Interleaved(slice::ChunksExact<'a, f32>),
}
impl Iterator for Frames<'_> {
    type Item = [f32; 2];
    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::Planar(frames) => frames.next().map(|(&left, &right)| [left, right]),
            Self::Interleaved(frames) => frames
                .next()
                .map(|frame| [frame[0], frame[frame.len() - 1]]),
        }
    }
    fn size_hint(&self) -> (usize, Option<usize>) {
        match self {
            Self::Planar(frames) => frames.size_hint(),
            Self::Interleaved(frames) => frames.size_hint(),
        }
    }
}
impl ExactSizeIterator for Frames<'_> {}

impl StereoInput {
    pub fn new(rate: u32, channels: usize) -> Self {
        Self {
            rate,
            channels,
            scratch: None,
        }
    }

    pub fn frames<'a>(
        &'a mut self,
        audio: AudioBufferRef<'a>,
        skip: &mut usize,
    ) -> Result<Frames<'a>> {
        let spec = *audio.spec();
        if spec.rate != self.rate || spec.channels.count() != self.channels {
            return decode_error("audio layout changed during playback");
        }
        if audio.capacity() > 65_536 {
            return decode_error("PCM input budget exceeded");
        }
        let discarded = (*skip).min(audio.frames());
        *skip -= discarded;
        match audio {
            AudioBufferRef::F32(Cow::Borrowed(buffer)) => {
                let end = buffer.frames();
                Ok(Frames::Planar(
                    buffer.chan(0)[discarded..end]
                        .iter()
                        .zip(&buffer.chan(self.channels - 1)[discarded..end]),
                ))
            }
            other => {
                let capacity = other.capacity();
                if capacity > 65_536 {
                    return decode_error("PCM input budget exceeded");
                }
                if self
                    .scratch
                    .as_ref()
                    .is_none_or(|buffer| buffer.capacity() < capacity * self.channels)
                {
                    self.scratch = Some(SampleBuffer::new(capacity as u64, spec));
                }
                let buffer =
                    self.scratch
                        .as_mut()
                        .ok_or(symphonia::core::errors::Error::DecodeError(
                            "missing conversion buffer",
                        ))?;
                buffer.copy_interleaved_ref(other);
                Ok(Frames::Interleaved(
                    buffer.samples()[discarded * self.channels..].chunks_exact(self.channels),
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{hint::black_box, time::Instant};
    use symphonia::core::audio::{AsAudioBufferRef, AudioBuffer, Layout, SignalSpec};

    #[test]
    fn borrowed_float_planes_use_valid_frames_and_keep_mono_stereo_semantics() {
        for layout in [Layout::Mono, Layout::Stereo] {
            let mut audio =
                AudioBuffer::<f32>::new(5760, SignalSpec::new_with_layout(48_000, layout));
            audio.render_reserved(Some(17));
            audio.chan_mut(0).fill(0.25);
            if audio.spec().channels.count() == 2 {
                audio.chan_mut(1).fill(-0.5);
            }
            let mut input = StereoInput::new(48_000, audio.spec().channels.count());
            let mut skip = 7;
            let frames: Vec<_> = input
                .frames(audio.as_audio_buffer_ref(), &mut skip)
                .unwrap()
                .collect();
            assert_eq!(skip, 0);
            assert_eq!(frames.len(), 10);
            assert_eq!(
                frames[0],
                [
                    0.25,
                    if matches!(layout, Layout::Mono) {
                        0.25
                    } else {
                        -0.5
                    }
                ]
            );
            assert!(input.scratch.is_none());
        }
    }

    #[test]
    fn integer_conversion_reuses_capacity_and_carries_skip_across_packets() {
        let mut audio =
            AudioBuffer::<i16>::new(960, SignalSpec::new_with_layout(44_100, Layout::Stereo));
        audio.render_reserved(Some(480));
        audio.chan_mut(0).fill(i16::MIN);
        audio.chan_mut(1).fill(0);
        let mut input = StereoInput::new(44_100, 2);
        let mut skip = 500;
        assert_eq!(
            input
                .frames(audio.as_audio_buffer_ref(), &mut skip)
                .unwrap()
                .len(),
            0
        );
        assert_eq!(skip, 20);
        let pointer = input.scratch.as_ref().unwrap().samples().as_ptr();
        let frames: Vec<_> = input
            .frames(audio.as_audio_buffer_ref(), &mut skip)
            .unwrap()
            .collect();
        assert_eq!(frames.len(), 460);
        assert_eq!(frames[0], [-1., 0.]);
        assert_eq!(pointer, input.scratch.as_ref().unwrap().samples().as_ptr());
    }

    #[test]
    #[ignore = "optimized stage benchmark; run with --release --ignored --nocapture"]
    fn benchmark_pcm_conversion() {
        let mut audio =
            AudioBuffer::<f32>::new(5760, SignalSpec::new_with_layout(48_000, Layout::Stereo));
        audio.render_reserved(Some(960));
        audio.chan_mut(0).fill(0.125);
        audio.chan_mut(1).fill(-0.0625);
        let iterations = 10_000;
        let start = Instant::now();
        let mut baseline = 0.;
        for _ in 0..iterations {
            let mut scratch = SampleBuffer::<f32>::new(audio.capacity() as u64, *audio.spec());
            scratch.copy_interleaved_ref(black_box(audio.as_audio_buffer_ref()));
            baseline += scratch
                .samples()
                .chunks_exact(2)
                .map(|frame| black_box(frame[0] + frame[1]))
                .sum::<f32>();
        }
        let baseline_us = start.elapsed().as_micros();
        let mut input = StereoInput::new(48_000, 2);
        let start = Instant::now();
        let mut candidate = 0.;
        for _ in 0..iterations {
            candidate += input
                .frames(black_box(audio.as_audio_buffer_ref()), &mut 0)
                .unwrap()
                .map(|frame| black_box(frame[0] + frame[1]))
                .sum::<f32>();
        }
        assert_eq!(black_box(candidate), black_box(baseline));
        println!("PCM_STAGE iterations={iterations} baseline_us={baseline_us} candidate_us={} removed_scratch_bytes_per_packet={}", start.elapsed().as_micros(), audio.capacity() * 2 * 4);
    }
}
