//! Bounded prepare-time measurements. These are Lixi policies, not Apple's
//! undisclosed metadata estimator or private AutoMix scoring model.
use crate::deck::{AudioError, Deck};
use ebur128::{EbuR128, Mode};
use rustfft::{num_complex::Complex, Fft, FftPlanner};
use serde::{Deserialize, Serialize};
use soundtouch::BPMDetect;
use std::{f32::consts::TAU, sync::Arc};

const FFT: usize = 16_384;
const MAX_BEATS: usize = 16_384;
const MAX_SAMPLES: u64 = 48_000 * 60 * 120;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub loudness_lufs: Option<f64>,
    pub true_peak_db: Option<f64>,
    pub bpm: Option<f64>,
    pub beat_confidence: f64,
    pub beat_offset_ms: f64,
    pub key: Option<u8>,
    pub key_confidence: f64,
    pub first_audio_ms: u64,
    pub last_audio_ms: u64,
    pub samples: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub sound_check: bool,
    pub auto_mix: bool,
    pub target_lufs: f64,
    pub peak_ceiling_db: f64,
    pub max_boost_db: f64,
    pub fade_ms: u64,
    pub max_tempo_change: f64,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_check: true,
            auto_mix: true,
            target_lufs: -16.,
            peak_ceiling_db: -1.,
            max_boost_db: 12.,
            fade_ms: 2500,
            max_tempo_change: 0.06,
        }
    }
}
impl Settings {
    pub fn valid(&self) -> bool {
        self.target_lufs.is_finite()
            && (-30. ..=-8.).contains(&self.target_lufs)
            && self.peak_ceiling_db.is_finite()
            && (-6. ..=0.).contains(&self.peak_ceiling_db)
            && self.max_boost_db.is_finite()
            && (0. ..=18.).contains(&self.max_boost_db)
            && self.fade_ms <= 12_000
            && self.max_tempo_change.is_finite()
            && (0. ..=0.12).contains(&self.max_tempo_change)
    }
    pub fn gain(&self, report: Option<&Report>) -> f32 {
        if !self.sound_check {
            return 1.;
        }
        let Some(report) = report else {
            return 1.;
        };
        let (Some(loudness), Some(peak)) = (report.loudness_lufs, report.true_peak_db) else {
            return 1.;
        };
        if !loudness.is_finite() || !peak.is_finite() {
            return 1.;
        }
        let db = (self.target_lufs - loudness)
            .min(self.peak_ceiling_db - peak)
            .min(self.max_boost_db);
        10f64.powf(db / 20.).clamp(0., 8.) as f32
    }
}

pub struct Analyzer {
    meter: EbuR128,
    rhythm: BPMDetect,
    fft: Arc<dyn Fft<f32>>,
    spectrum: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    window: [f32; FFT],
    fill: usize,
    chroma: [f64; 12],
    samples: u64,
    first: Option<u64>,
    last: u64,
}
impl Analyzer {
    pub fn new() -> Result<Self, AudioError> {
        let fft = FftPlanner::new().plan_fft_forward(FFT);
        let scratch = vec![Complex::default(); fft.get_inplace_scratch_len()];
        Ok(Self {
            meter: EbuR128::new(2, 48_000, Mode::I | Mode::TRUE_PEAK | Mode::HISTOGRAM)?,
            rhythm: BPMDetect::new(2, 48_000),
            fft,
            spectrum: vec![Complex::default(); FFT],
            scratch,
            window: [0.; FFT],
            fill: 0,
            chroma: [0.; 12],
            samples: 0,
            first: None,
            last: 0,
        })
    }
    pub fn feed(&mut self, samples: &[f32]) -> Result<(), AudioError> {
        if self.samples + samples.len() as u64 / 2 > MAX_SAMPLES {
            return Err("analysis exceeds two-hour budget".into());
        }
        if samples.iter().any(|sample| !sample.is_finite()) {
            return Err("non-finite analysis PCM".into());
        }
        self.meter.add_frames_f32(samples)?;
        for frame in samples.chunks_exact(2) {
            if frame[0].abs().max(frame[1].abs()) > 0.001 {
                self.first.get_or_insert(self.samples);
                self.last = self.samples + 1;
            }
            self.window[self.fill] = (frame[0] + frame[1]) * 0.5;
            self.fill += 1;
            if self.fill == FFT {
                self.transform();
                self.fill = 0;
            }
            self.samples += 1;
        }
        self.rhythm.input_samples(samples);
        Ok(())
    }
    fn transform(&mut self) {
        for (index, sample) in self.window.iter().enumerate() {
            self.spectrum[index] = Complex::new(
                sample * (0.5 - 0.5 * (TAU * index as f32 / FFT as f32).cos()),
                0.,
            );
        }
        self.fft
            .process_with_scratch(&mut self.spectrum, &mut self.scratch);
        for index in 2..FFT / 2 - 1 {
            let center = self.spectrum[index].norm_sqr();
            let left = self.spectrum[index - 1].norm_sqr();
            let right = self.spectrum[index + 1].norm_sqr();
            if center <= 1e-12 || center <= left || center < right {
                continue;
            }
            // A bin's nominal frequency can be a semitone away in the bass.
            // Interpolate isolated Hann-window peaks in log power before folding octaves.
            let logs = [left.max(1e-12).ln(), center.ln(), right.max(1e-12).ln()];
            let denominator = logs[0] - 2. * logs[1] + logs[2];
            let offset = if denominator.abs() > 1e-8 {
                (0.5 * (logs[0] - logs[2]) / denominator).clamp(-0.5, 0.5)
            } else {
                0.
            };
            let frequency = (index as f64 + f64::from(offset)) * 48_000. / FFT as f64;
            if !(55. ..=5000.).contains(&frequency) {
                continue;
            }
            let midi = 69. + 12. * (frequency / 440.).log2();
            let note = midi.round() as i32;
            let tuning = (1. - 2. * (midi - f64::from(note)).abs()).max(0.);
            self.chroma[note.rem_euclid(12) as usize] += f64::from(center.sqrt()) * tuning;
        }
    }
    pub fn finish(mut self) -> Report {
        if self.fill > 0 {
            self.window[self.fill..].fill(0.);
            self.transform();
        }
        let bpm = f64::from(self.rhythm.get_bpm());
        let count = self
            .rhythm
            .query_size(MAX_BEATS as i32)
            .clamp(0, MAX_BEATS as i32) as usize;
        let mut positions = vec![0.; count];
        let mut strengths = vec![0.; count];
        let written = self
            .rhythm
            .get_beats(&mut positions, &mut strengths, count as i32)
            .max(0) as usize;
        positions.truncate(written.min(count));
        strengths.truncate(written.min(count));
        let mut values = strengths.clone();
        values.sort_by(f32::total_cmp);
        let threshold = values
            .get(values.len() / 2)
            .copied()
            .unwrap_or(f32::INFINITY);
        let beats: Vec<_> = positions
            .iter()
            .zip(strengths)
            .filter_map(|(&position, strength)| {
                (strength >= threshold && strength > 0.).then_some(f64::from(position))
            })
            .collect();
        let (confidence, offset) = beat_quality(bpm, &beats);
        let (key, key_confidence) = detect_key(&self.chroma);
        let loudness = self.meter.loudness_global().ok().filter(|v| v.is_finite());
        // Flush the true-peak interpolation tail without adding silence to the loudness result.
        let _ = self.meter.add_frames_f32(&[0.; 96]);
        let peak = self
            .meter
            .true_peak(0)
            .unwrap_or(0.)
            .max(self.meter.true_peak(1).unwrap_or(0.));
        Report {
            loudness_lufs: loudness,
            true_peak_db: (peak > 0. && peak.is_finite()).then(|| 20. * peak.log10()),
            bpm: (bpm.is_finite() && (45. ..=240.).contains(&bpm) && confidence > 0.15)
                .then_some(bpm),
            beat_confidence: confidence,
            beat_offset_ms: offset * 1000.,
            key,
            key_confidence,
            first_audio_ms: self.first.unwrap_or(0) / 48,
            last_audio_ms: self.last / 48,
            samples: self.samples,
        }
    }
}

fn beat_quality(bpm: f64, beats: &[f64]) -> (f64, f64) {
    if !bpm.is_finite() || bpm <= 0. || beats.len() < 8 {
        return (0., 0.);
    }
    let period = 60. / bpm;
    let mut x = 0.;
    let mut y = 0.;
    for beat in beats {
        let phase = beat / period * std::f64::consts::TAU;
        x += phase.cos();
        y += phase.sin();
    }
    let confidence = x.hypot(y) / beats.len() as f64;
    (
        confidence,
        y.atan2(x).rem_euclid(std::f64::consts::TAU) / std::f64::consts::TAU * period,
    )
}
fn detect_key(chroma: &[f64; 12]) -> (Option<u8>, f64) {
    const MAJOR: [f64; 12] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ];
    const MINOR: [f64; 12] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ];
    let sum: f64 = chroma.iter().sum();
    if sum <= 1e-12 || !sum.is_finite() {
        return (None, 0.);
    }
    let centered = chroma.map(|value| value - sum / 12.);
    let norm = centered
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt();
    if norm / sum < 0.03 {
        return (None, 0.);
    }
    let mut scores = Vec::with_capacity(24);
    for (mode, profile) in [MAJOR, MINOR].iter().enumerate() {
        let mean = profile.iter().sum::<f64>() / 12.;
        let profile_norm = profile
            .iter()
            .map(|value| (value - mean).powi(2))
            .sum::<f64>()
            .sqrt();
        for root in 0..12 {
            let score: f64 = (0..12)
                .map(|note| centered[(root + note) % 12] * (profile[note] - mean))
                .sum::<f64>()
                / (norm * profile_norm);
            scores.push(((mode * 12 + root) as u8, score));
        }
    }
    scores.sort_by(|a, b| b.1.total_cmp(&a.1));
    let confidence = (scores[0].1 - scores[1].1).clamp(0., 1.);
    (Some(scores[0].0), confidence)
}

pub fn measure(deck: &mut Deck) -> Result<Report, AudioError> {
    let mut analyzer = Analyzer::new()?;
    while let Some(frame) = deck.frame()? {
        analyzer.feed(&frame.samples[..frame.valid * 2])?;
    }
    Ok(analyzer.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sound_check_uses_constant_loudness_gain_and_true_peak_ceiling() {
        let settings = Settings::default();
        let quiet = Report {
            loudness_lufs: Some(-26.),
            true_peak_db: Some(-12.),
            ..Default::default()
        };
        assert!((settings.gain(Some(&quiet)) - 10f32.powf(10. / 20.)).abs() < 1e-5);
        let dynamic = Report {
            loudness_lufs: Some(-26.),
            true_peak_db: Some(-2.),
            ..Default::default()
        };
        assert!((settings.gain(Some(&dynamic)) - 10f32.powf(1. / 20.)).abs() < 1e-5);
        assert_eq!(settings.gain(Some(&Report::default())), 1.);
    }
    #[test]
    fn measured_quiet_and_loud_tracks_converge_without_peak_overload() {
        let settings = Settings::default();
        let mut results = Vec::new();
        for amplitude in [0.05f32, 0.4] {
            let mut analyzer = Analyzer::new().unwrap();
            let mut pcm = [0.; 1920];
            for block in 0..150 {
                for (i, frame) in pcm.chunks_exact_mut(2).enumerate() {
                    let sample =
                        amplitude * (TAU * 1000. * (block * 960 + i) as f32 / 48_000.).sin();
                    frame.fill(sample);
                }
                analyzer.feed(&pcm).unwrap();
            }
            let report = analyzer.finish();
            let gain_db = 20. * f64::from(settings.gain(Some(&report))).log10();
            results.push(report.loudness_lufs.unwrap() + gain_db);
            assert!(report.true_peak_db.unwrap() + gain_db <= settings.peak_ceiling_db + 0.0001);
        }
        assert!((results[0] - results[1]).abs() < 0.01);
        assert!((results[0] - settings.target_lufs).abs() < 0.01);
    }
    #[test]
    fn periodic_tonal_audio_reaches_the_beat_matched_transition_path() {
        let mut analyzer = Analyzer::new().unwrap();
        let mut pcm = [0.; 1920];
        for block in 0..1600 {
            for (index, stereo) in pcm.chunks_exact_mut(2).enumerate() {
                let sample = block * 960 + index;
                let time = sample as f32 / 48_000.;
                let phase = (sample % 24_000) as f32 / 48_000.;
                let kick = 0.75 * (-40. * phase).exp() * (TAU * 65.406 * phase).sin();
                let chord = [261.626, 329.628, 391.995]
                    .iter()
                    .map(|frequency| (TAU * frequency * time).sin())
                    .sum::<f32>()
                    * 0.03;
                stereo.fill(kick + chord);
            }
            analyzer.feed(&pcm).unwrap();
        }
        let report = analyzer.finish();
        assert!(
            report.bpm.is_some_and(|bpm| (bpm - 120.).abs() < 1.),
            "{report:?}"
        );
        assert!(report.beat_confidence >= 0.55, "{report:?}");
        assert_eq!(report.key, Some(0), "{report:?}");
        let result = plan(
            &Settings::default(),
            Some(&report),
            &report,
            32_000,
            32_000,
            1.,
        );
        assert_eq!(result.mode, "beatMatched", "{report:?}");
    }
    #[test]
    fn silence_is_finite_and_does_not_trigger_amplification_or_tempo_guess() {
        let mut analyzer = Analyzer::new().unwrap();
        analyzer.feed(&vec![0.; 48_000 * 2]).unwrap();
        let report = analyzer.finish();
        assert!(report.loudness_lufs.is_none());
        assert!(report.bpm.is_none());
        assert!(report.key.is_none());
        assert_eq!(Settings::default().gain(Some(&report)), 1.);
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub mode: &'static str,
    pub start_ms: f64,
    pub fade_samples: u64,
    pub cue_in_ms: u64,
    pub tempo_multiplier: f64,
}
pub fn plan(
    settings: &Settings,
    current: Option<&Report>,
    next: &Report,
    current_length: u64,
    next_length: u64,
    source_speed: f64,
) -> Plan {
    let mut fade = if settings.auto_mix {
        settings
            .fade_ms
            .min(current_length / 3)
            .min(next_length / 3)
    } else {
        0
    };
    let end = current.map_or(current_length, |report| {
        if settings.auto_mix && report.last_audio_ms > 0 {
            report
                .last_audio_ms
                .clamp(current_length.saturating_sub(8000), current_length)
        } else {
            current_length
        }
    });
    let mut cue = if settings.auto_mix {
        next.first_audio_ms.min(8000)
    } else {
        0
    };
    let mut start = end.saturating_sub(fade) as f64;
    let mut multiplier = 1.;
    let mut mode = if fade == 0 { "gapless" } else { "crossfade" };
    if let Some(a) = current {
        if let (Some(a_bpm), Some(b_bpm)) = (a.bpm, next.bpm) {
            let ratio = a_bpm / b_bpm;
            if settings.auto_mix
                && a.beat_confidence >= 0.55
                && next.beat_confidence >= 0.55
                && (ratio - 1.).abs() <= settings.max_tempo_change
                && compatible_keys(a, next)
            {
                let beat_ms = 60_000. / a_bpm;
                let available = (fade as f64 / beat_ms).floor() as u64;
                let beats = if available >= 8 {
                    8
                } else if available >= 4 {
                    4
                } else if available >= 2 {
                    2
                } else {
                    0
                };
                if beats > 0 {
                    multiplier = ratio;
                    fade = (beat_ms * beats as f64).round() as u64;
                    let latest = end.saturating_sub(fade) as f64;
                    start = (a.beat_offset_ms
                        + ((latest - a.beat_offset_ms) / beat_ms).floor() * beat_ms)
                        .max(0.);
                    cue = (next.beat_offset_ms
                        + ((cue as f64 - next.beat_offset_ms) / (60_000. / b_bpm))
                            .ceil()
                            .max(0.)
                            * (60_000. / b_bpm))
                        .round()
                        .max(0.) as u64;
                    mode = "beatMatched";
                }
            }
        }
    }
    // Cue trimming and tempo matching reduce the incoming deck's usable tail.
    // Reserve a frame so rounding cannot consume it before the fade completes.
    cue = cue.min(next_length.saturating_sub(20));
    let remaining = next_length.saturating_sub(cue).saturating_sub(20);
    let incoming_limit = (remaining as f64 / multiplier).floor() as u64;
    if fade > incoming_limit {
        fade = remaining.min(fade);
        multiplier = 1.;
        mode = if fade == 0 { "gapless" } else { "crossfade" };
        start = end.saturating_sub(fade) as f64;
    }
    Plan {
        mode,
        start_ms: start,
        fade_samples: (fade as f64 * 48. / source_speed.max(0.01)).round() as u64,
        cue_in_ms: cue,
        tempo_multiplier: multiplier,
    }
}
fn compatible_keys(a: &Report, b: &Report) -> bool {
    if a.key_confidence < 0.015 || b.key_confidence < 0.015 {
        return false;
    }
    match (a.key, b.key) {
        (Some(a), Some(b)) if a < 24 && b < 24 => {
            let root_a = a % 12;
            let root_b = b % 12;
            root_a == root_b
                || (a / 12 == b / 12 && matches!((root_b + 12 - root_a) % 12, 5 | 7))
                || (a < 12 && b >= 12 && (root_a + 9) % 12 == root_b)
                || (b < 12 && a >= 12 && (root_b + 9) % 12 == root_a)
        }
        _ => false,
    }
}

pub struct Limiter {
    gain: f32,
    meter: EbuR128,
}
impl Limiter {
    pub fn new() -> Result<Self, AudioError> {
        Ok(Self {
            gain: 1.,
            meter: EbuR128::new(2, 48_000, Mode::TRUE_PEAK)?,
        })
    }
    pub fn process(&mut self, samples: &mut [f32], ceiling_db: f64) -> Result<(), AudioError> {
        for sample in samples.iter_mut() {
            if !sample.is_finite() {
                *sample = 0.;
            }
        }
        self.meter.add_frames_f32(samples)?;
        let ceiling = 10f64.powf(ceiling_db / 20.) as f32;
        let sample_peak = samples
            .iter()
            .copied()
            .filter(|v| v.is_finite())
            .map(f32::abs)
            .fold(0., f32::max);
        let peak = (self
            .meter
            .prev_true_peak(0)?
            .max(self.meter.prev_true_peak(1)?) as f32)
            .max(sample_peak);
        let required = if peak > ceiling { ceiling / peak } else { 1. };
        self.gain = required.min(self.gain + (1. - self.gain) * 0.08);
        for sample in samples {
            *sample = if sample.is_finite() {
                (*sample * self.gain).clamp(-ceiling, ceiling)
            } else {
                0.
            };
        }
        Ok(())
    }
}

#[cfg(test)]
mod transition_tests {
    use super::*;
    #[test]
    fn uncertain_music_falls_back_and_tempo_matching_is_bounded() {
        let settings = Settings::default();
        let fallback = plan(&settings, None, &Report::default(), 60_000, 60_000, 1.);
        assert_eq!(fallback.mode, "crossfade");
        assert_eq!(fallback.tempo_multiplier, 1.);
        let a = Report {
            bpm: Some(120.),
            beat_confidence: 0.9,
            key: Some(0),
            key_confidence: 0.1,
            ..Default::default()
        };
        let b = Report {
            bpm: Some(124.),
            beat_confidence: 0.9,
            key: Some(7),
            key_confidence: 0.1,
            ..Default::default()
        };
        let matched = plan(&settings, Some(&a), &b, 60_000, 60_000, 1.);
        assert_eq!(matched.mode, "beatMatched");
        assert!((matched.tempo_multiplier - 120. / 124.).abs() < 1e-12);
        assert_eq!(matched.fade_samples, 2000 * 48);
        let fast = plan(&settings, Some(&a), &b, 60_000, 60_000, 2.);
        assert_eq!(fast.fade_samples, matched.fade_samples / 2);
        let disabled = Settings {
            auto_mix: false,
            ..settings
        };
        assert_eq!(
            plan(&disabled, Some(&a), &b, 60_000, 60_000, 1.).fade_samples,
            0
        );
    }
    #[test]
    fn cue_trim_leaves_enough_incoming_audio_for_the_fade() {
        let next = Report {
            first_audio_ms: 8000,
            ..Default::default()
        };
        let result = plan(&Settings::default(), None, &next, 60_000, 9500, 1.);
        assert!(result.fade_samples <= (9500 - result.cue_in_ms) * 48);
        assert_eq!(result.tempo_multiplier, 1.);
        let short = plan(&Settings::default(), None, &next, 300, 310, 1.);
        assert_eq!(short.mode, "gapless");
    }
    #[test]
    fn post_mix_limiter_protects_correlated_signals_and_recovers_smoothly() {
        let mut limiter = Limiter::new().unwrap();
        let ceiling = 10f32.powf(-1. / 20.);
        let mut data = [1.4, -1.4, 0.7, -0.7];
        limiter.process(&mut data, -1.).unwrap();
        assert!(data.iter().all(|v| v.abs() <= ceiling));
        let mut quiet = [0.1; 1920];
        limiter.process(&mut quiet, -1.).unwrap();
        assert!(quiet[0] > 0.06 && quiet[0] < 0.1);
    }
}
