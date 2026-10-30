use serde_json::Value;
use soundtouch::SoundTouch;
use std::collections::VecDeque;

pub struct Timescale {
    processor: Option<SoundTouch>,
    scratch: Vec<f32>,
    pub speed: f64,
}

impl Timescale {
    pub fn new(config: &Value) -> Self {
        let number = |name: &str| config["timescale"][name].as_f64().unwrap_or(1.0);
        let speed = number("speed");
        let rate = number("rate");
        let pitch = number("pitch");
        let processor = if speed == 1.0 && rate == 1.0 && pitch == 1.0 {
            None
        } else {
            let mut processor = SoundTouch::new();
            processor
                .set_channels(2)
                .set_sample_rate(48_000)
                .set_tempo(speed)
                .set_rate(rate)
                .set_pitch(pitch);
            Some(processor)
        };
        Self {
            processor,
            scratch: Vec::new(),
            speed: speed * rate,
        }
    }

    pub fn feed(
        &mut self,
        frames: impl Iterator<Item = [f32; 2]>,
        output: &mut VecDeque<[f32; 2]>,
    ) -> Result<(), &'static str> {
        if let Some(processor) = &mut self.processor {
            self.scratch.clear();
            self.scratch.extend(frames.flatten());
            processor.put_samples(&self.scratch, self.scratch.len() / 2);
            Self::drain(processor, output)?;
        } else {
            output.extend(frames);
        }
        if output.len() > 65_536 {
            return Err("PCM output budget exceeded");
        }
        Ok(())
    }

    pub fn flush(&mut self, output: &mut VecDeque<[f32; 2]>) -> Result<(), &'static str> {
        if let Some(processor) = &mut self.processor {
            if processor.num_unprocessed_samples() > 0 {
                processor.flush();
            }
            Self::drain(processor, output)?;
        }
        Ok(())
    }

    fn drain(
        processor: &mut SoundTouch,
        output: &mut VecDeque<[f32; 2]>,
    ) -> Result<(), &'static str> {
        let mut block = [0.; 3840];
        loop {
            let count = processor.receive_samples(&mut block, 1920);
            if count == 0 {
                break;
            }
            if output.len() + count > 65_536 {
                return Err("PCM output budget exceeded");
            }
            output.extend(block[..count * 2].chunks_exact(2).map(|s| [s[0], s[1]]));
        }
        Ok(())
    }
}
