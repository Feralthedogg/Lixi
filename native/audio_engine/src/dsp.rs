use serde_json::Value;
use std::f32::consts::TAU;

struct Band {
    b: [f32; 3],
    a: [f32; 2],
    history: [[f32; 2]; 2],
}

impl Band {
    fn peak(frequency: f32, gain: f32) -> Self {
        let a = (1.0 + gain * 3.0).max(0.01).sqrt();
        let w = TAU * frequency / 48_000.0;
        let alpha = w.sin() / 2.8;
        let a0 = 1.0 + alpha / a;
        Self {
            b: [
                (1.0 + alpha * a) / a0,
                -2.0 * w.cos() / a0,
                (1.0 - alpha * a) / a0,
            ],
            a: [-2.0 * w.cos() / a0, (1.0 - alpha / a) / a0],
            history: [[0.0; 2]; 2],
        }
    }
    fn pass(frequency: f32, width: f32) -> Self {
        let frequency = frequency.clamp(1., 23_999.);
        let w = TAU * frequency / 48_000.;
        let alpha = w.sin() * width.max(1.) / (2. * frequency);
        let divisor = 1. + alpha;
        Self {
            b: [alpha / divisor, 0., -alpha / divisor],
            a: [-2. * w.cos() / divisor, (1. - alpha) / divisor],
            history: [[0.; 2]; 2],
        }
    }
    fn process(&mut self, frame: &mut [f32; 2]) {
        for (channel, sample) in frame.iter_mut().enumerate() {
            let out = self.b[0] * *sample + self.history[channel][0];
            self.history[channel][0] =
                self.b[1] * *sample - self.a[0] * out + self.history[channel][1];
            self.history[channel][1] = self.b[2] * *sample - self.a[1] * out;
            *sample = out;
        }
    }
}

struct Oscillator {
    phase: f32,
    step: f32,
}
impl Oscillator {
    fn new(frequency: f32) -> Self {
        Self {
            phase: 0.,
            step: TAU * frequency / 48_000.,
        }
    }
    fn next(&mut self) -> f32 {
        let sample = self.phase.sin();
        self.phase += self.step;
        if self.phase >= TAU {
            self.phase -= TAU;
        }
        if self.phase < 0. {
            self.phase += TAU;
        }
        sample
    }
}

struct Karaoke {
    band: Band,
    level: f32,
    mono: f32,
}
struct Tremolo {
    oscillator: Oscillator,
    depth: f32,
}
struct Vibrato {
    oscillator: Oscillator,
    depth: f32,
    delay: [[f32; 2]; 512],
    index: usize,
}

pub struct Dsp {
    volume: f32,
    bands: Vec<Band>,
    mix: Option<[f32; 4]>,
    low_pass: Option<f32>,
    previous: [f32; 2],
    karaoke: Option<Karaoke>,
    tremolo: Option<Tremolo>,
    rotation: Option<Oscillator>,
    distortion: Option<[f32; 8]>,
    vibrato: Option<Box<Vibrato>>,
}

fn number(config: &Value, section: &str, key: &str, default: f32) -> f32 {
    config[section][key].as_f64().map_or(default, |n| n as f32)
}

impl Dsp {
    pub fn new(config: Value) -> Self {
        let frequencies = [
            25., 40., 63., 100., 160., 250., 400., 630., 1000., 1600., 2500., 4000., 6300., 10000.,
            16000.,
        ];
        let mut gains = [0.; 15];
        for band in config["equalizer"].as_array().into_iter().flatten() {
            if let (Some(index), Some(gain)) = (band["band"].as_u64(), band["gain"].as_f64()) {
                if let Some(value) = gains.get_mut(index as usize) {
                    *value = gain as f32;
                }
            }
        }
        let bands = gains
            .into_iter()
            .zip(frequencies)
            .filter(|(gain, _)| *gain != 0.)
            .map(|(gain, frequency)| Band::peak(frequency, gain))
            .collect();
        Self {
            volume: config["volume"].as_f64().unwrap_or(1.0) as f32,
            bands,
            mix: config.get("channelMix").map(|_| {
                [
                    number(&config, "channelMix", "leftToLeft", 1.),
                    number(&config, "channelMix", "rightToLeft", 0.),
                    number(&config, "channelMix", "leftToRight", 0.),
                    number(&config, "channelMix", "rightToRight", 1.),
                ]
            }),
            low_pass: config
                .get("lowPass")
                .map(|_| number(&config, "lowPass", "smoothing", 20.).max(1.)),
            previous: [0.; 2],
            karaoke: config.get("karaoke").map(|_| Karaoke {
                band: Band::pass(
                    number(&config, "karaoke", "filterBand", 220.),
                    number(&config, "karaoke", "filterWidth", 100.),
                ),
                level: number(&config, "karaoke", "level", 1.),
                mono: number(&config, "karaoke", "monoLevel", 1.),
            }),
            tremolo: config.get("tremolo").map(|_| Tremolo {
                oscillator: Oscillator::new(number(&config, "tremolo", "frequency", 2.)),
                depth: number(&config, "tremolo", "depth", 0.5),
            }),
            rotation: config
                .get("rotation")
                .map(|_| Oscillator::new(number(&config, "rotation", "rotationHz", 0.))),
            distortion: config.get("distortion").map(|_| {
                [
                    number(&config, "distortion", "sinOffset", 0.),
                    number(&config, "distortion", "sinScale", 0.),
                    number(&config, "distortion", "cosOffset", 0.),
                    number(&config, "distortion", "cosScale", 0.),
                    number(&config, "distortion", "tanOffset", 0.),
                    number(&config, "distortion", "tanScale", 0.),
                    number(&config, "distortion", "offset", 0.),
                    number(&config, "distortion", "scale", 1.),
                ]
            }),
            vibrato: config.get("vibrato").map(|_| {
                Box::new(Vibrato {
                    oscillator: Oscillator::new(number(&config, "vibrato", "frequency", 2.)),
                    depth: number(&config, "vibrato", "depth", 0.5),
                    delay: [[0.; 2]; 512],
                    index: 0,
                })
            }),
        }
    }

    pub fn process(&mut self, frame: &mut [f32; 2], gain: f32) {
        self.process_inner(frame, gain, true);
    }
    pub fn process_mix(&mut self, frame: &mut [f32; 2], gain: f32) {
        self.process_inner(frame, gain, false);
    }
    fn process_inner(&mut self, frame: &mut [f32; 2], gain: f32, clip: bool) {
        for band in &mut self.bands {
            band.process(frame);
        }
        if let Some(karaoke) = &mut self.karaoke {
            let mid = (frame[0] + frame[1]) * 0.5;
            let side = (frame[0] - frame[1]) * 0.5;
            let mut band = [mid, mid];
            karaoke.band.process(&mut band);
            let mid = (mid - band[0] * karaoke.level) * karaoke.mono;
            *frame = [mid + side, mid - side];
        }
        if let Some(mix) = self.mix {
            *frame = [
                frame[0] * mix[0] + frame[1] * mix[1],
                frame[0] * mix[2] + frame[1] * mix[3],
            ];
        }
        if let Some(smoothing) = self.low_pass {
            for (channel, sample) in frame.iter_mut().enumerate() {
                *sample = self.previous[channel] + (*sample - self.previous[channel]) / smoothing;
                self.previous[channel] = *sample;
            }
        }
        if let Some(vibrato) = &mut self.vibrato {
            vibrato.delay[vibrato.index] = *frame;
            let offset = (vibrato.oscillator.next() * 0.5 + 0.5) * vibrato.depth * 240.;
            let read = (vibrato.index as f32 - offset).rem_euclid(512.);
            let index = read.floor() as usize;
            let fraction = read.fract();
            for (channel, sample) in frame.iter_mut().enumerate() {
                *sample = vibrato.delay[index][channel] * (1. - fraction)
                    + vibrato.delay[(index + 1) % 512][channel] * fraction;
            }
            vibrato.index = (vibrato.index + 1) % 512;
        }
        let tremolo = self.tremolo.as_mut().map_or(1., |t| {
            1. - t.depth * 0.5 + t.depth * 0.5 * t.oscillator.next()
        });
        let pan = self.rotation.as_mut().map(|r| r.next() * 0.5 + 0.5);
        for (channel, sample) in frame.iter_mut().enumerate() {
            if let Some(
                [sin_offset, sin_scale, cos_offset, cos_scale, tan_offset, tan_scale, offset, scale],
            ) = self.distortion
            {
                let input = *sample;
                *sample = sin_scale * (input + sin_offset).sin()
                    + cos_scale * (input + cos_offset).cos()
                    + tan_scale * (input + tan_offset).tan()
                    + offset
                    + scale * input;
            }
            let pan = pan.map_or(1., |p| if channel == 0 { p } else { 1. - p });
            *sample = *sample * self.volume * gain * tremolo * pan;
            if clip {
                *sample = sample.clamp(-1., 1.);
            }
            if !sample.is_finite() {
                *sample = 0.;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn defaults_preserve_samples_and_volume_and_mix_are_applied() {
        let mut frame = [0.5, -0.25];
        Dsp::new(Value::Null).process(&mut frame, 1.);
        assert_eq!(frame, [0.5, -0.25]);
        let mut dsp = Dsp::new(
            json!({"volume": 0.5, "channelMix": {"leftToLeft": 0., "rightToLeft": 1., "leftToRight": 1., "rightToRight": 0.}}),
        );
        dsp.process(&mut frame, 1.);
        assert_eq!(frame, [-0.125, 0.25]);
    }
    #[test]
    fn all_sample_filters_remain_finite_and_bounded() {
        let mut dsp = Dsp::new(
            json!({"equalizer": [{"band": 1, "gain": 0.5}], "karaoke": {}, "lowPass": {},
            "tremolo": {}, "rotation": {"rotationHz": 0.2}, "vibrato": {}, "distortion": {"tanScale": 10.}}),
        );
        for i in 0..96_000 {
            let mut frame = [(i as f32 * std::f32::consts::PI / 48.).sin(); 2];
            dsp.process(&mut frame, 10.);
            assert!(frame.iter().all(|x| x.is_finite() && x.abs() <= 1.));
        }
    }
}
