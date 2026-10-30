//! One continuous encoder, a current PCM deck and a bounded prepared-next deck.
use crate::{
    analysis::{self, Limiter, Plan, Report, Settings},
    deck::{AudioError, Deck, PcmFrame},
    dsp,
    protocol::Wire,
    source::{Slot, Source},
    Open, Shared,
};
use opus::{Application, Channels, Encoder};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};
use std::thread::JoinHandle;

#[derive(Clone, Deserialize)]
pub struct Next {
    pub slot: u8,
    pub tag: u64,
    pub open: Open,
    pub analysis: Report,
}
pub enum Command {
    Next(Box<Next>),
    Cancel(u64),
    Settings(Settings),
    Skip,
}

struct Cursor {
    tag: u64,
    slot: u8,
    deck: Deck,
    frame: Option<PcmFrame>,
    offset: usize,
    position: f64,
    report: Option<Report>,
    gain: f32,
    multiplier: f64,
}
impl Cursor {
    fn new(
        tag: u64,
        slot: u8,
        mut deck: Deck,
        report: Option<Report>,
        settings: &Settings,
    ) -> Result<Self, AudioError> {
        let frame = deck.frame()?;
        let position = frame.as_ref().map_or(0., |frame| frame.source_start_ms);
        Ok(Self {
            tag,
            slot,
            deck,
            frame,
            offset: 0,
            position,
            gain: settings.gain(report.as_ref()),
            report,
            multiplier: 1.,
        })
    }
    fn sample(&mut self) -> Result<Option<[f32; 2]>, AudioError> {
        if self
            .frame
            .as_ref()
            .is_some_and(|frame| self.offset >= frame.valid)
        {
            self.frame = self.deck.frame()?;
            self.offset = 0;
        }
        let Some(frame) = &self.frame else {
            return Ok(None);
        };
        let at = self.offset * 2;
        let sample = [
            frame.samples[at] * self.gain,
            frame.samples[at + 1] * self.gain,
        ];
        self.offset += 1;
        self.position = (frame.source_start_ms + self.offset as f64 * frame.source_step_ms)
            .min(self.deck.length_ms as f64);
        Ok(Some(sample))
    }
}
struct Opening {
    tag: u64,
    slot: u8,
    cancel: Arc<AtomicBool>,
    settings: Settings,
    received: mpsc::Receiver<Result<(Cursor, Plan), String>>,
    thread: JoinHandle<()>,
}

fn event(wire: &Wire, value: Value) -> Result<(), AudioError> {
    wire.send(17, 0, &serde_json::to_vec(&value)?)?;
    Ok(())
}
fn source(
    open: &Open,
    wire: &Wire,
    slot: Slot,
    running: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
) -> Source {
    Source::with_slot(open.length, wire.clone(), slot, running, cancel)
}

pub fn prepare(
    open: Open,
    wire: Wire,
    slot: Slot,
    running: Arc<AtomicBool>,
    control: Shared,
) -> Result<(), AudioError> {
    let mut measure_open = open.clone();
    measure_open.position = 0;
    measure_open.end_time = None;
    measure_open.filters = json!({});
    measure_open.tempo_multiplier = 1.;
    let cancel = Arc::new(AtomicBool::new(false));
    let mut measured = Deck::open(
        &measure_open,
        source(
            &measure_open,
            &wire,
            slot.clone(),
            running.clone(),
            cancel.clone(),
        ),
    )?;
    let metadata = measured.metadata();
    let report = analysis::measure(&mut measured)?;
    drop(measured);
    let mut preview = Deck::open(&open, source(&open, &wire, slot, running.clone(), cancel))?;
    let mut frames = Vec::with_capacity(15);
    for _ in 0..15 {
        if let Some(frame) = preview.frame()? {
            frames.push(frame);
        } else {
            break;
        }
    }
    if frames.is_empty() {
        return Err("prepared track has no samples".into());
    }
    let mut metadata = metadata;
    metadata["analysis"] = serde_json::to_value(report)?;
    metadata["preparedFrames"] = json!(frames.len());
    wire.send(2, 0, &serde_json::to_vec(&metadata)?)?;
    let mut state = control.0.lock().map_err(|_| "control lock poisoned")?;
    while running.load(Ordering::Acquire) {
        state = control.1.wait(state).map_err(|_| "control lock poisoned")?;
    }
    Ok(())
}

pub fn render(
    open: Open,
    wire: Wire,
    slots: [Slot; 2],
    running: Arc<AtomicBool>,
    control: Shared,
) -> Result<(), AudioError> {
    let mut settings = open.swapping.clone().ok_or("missing Swapping settings")?;
    let initial_cancel = Arc::new(AtomicBool::new(false));
    let report = if let Some(report) = open.report.clone() {
        Some(report)
    } else {
        let mut raw = open.clone();
        raw.position = 0;
        raw.end_time = None;
        raw.filters = json!({});
        raw.tempo_multiplier = 1.;
        let mut deck = Deck::open(
            &raw,
            source(
                &raw,
                &wire,
                slots[0].clone(),
                running.clone(),
                initial_cancel.clone(),
            ),
        )?;
        Some(analysis::measure(&mut deck)?)
    };
    let deck = Deck::open(
        &open,
        source(
            &open,
            &wire,
            slots[0].clone(),
            running.clone(),
            initial_cancel,
        ),
    )?;
    let mut metadata = deck.metadata();
    metadata["analysis"] = serde_json::to_value(&report)?;
    metadata["tag"] = json!(open.tag);
    wire.send(2, 0, &serde_json::to_vec(&metadata)?)?;
    let mut current = Some(Cursor::new(open.tag, 0, deck, report, &settings)?);
    let mut next: Option<Cursor> = None;
    let mut opening: Option<Opening> = None;
    let mut plan: Option<Plan> = None;
    let mut fade: Option<(u64, u64)> = None;
    let mut ramp: Option<(f64, u64, u64)> = None;
    let mut encoder = Encoder::new(48_000, Channels::Stereo, Application::Audio)?;
    encoder.set_bitrate(opus::Bitrate::Bits(96_000))?;
    let mut dsp = dsp::Dsp::new(open.filters.clone());
    let mut limiter = Limiter::new()?;

    while running.load(Ordering::Acquire) {
        let (commands, gain, can_render, revision, ordinal) = {
            let mut state = control.0.lock().map_err(|_| "control lock poisoned")?;
            (
                std::mem::take(&mut state.commands),
                state.gain,
                state.emitted < state.limit,
                state.revision,
                state.emitted,
            )
        };
        for command in commands {
            match command {
                Command::Next(mut request) => {
                    if request.slot > 1
                        || request.open.length == 0
                        || opening.is_some()
                        || next.is_some()
                        || current
                            .as_ref()
                            .is_some_and(|a| a.slot == request.slot || a.tag == request.tag)
                    {
                        event(
                            &wire,
                            json!({"type":"prepareFailed","tag":request.tag,"slot":request.slot,"message":"Next deck is occupied"}),
                        )?;
                        continue;
                    }
                    let a_report = current.as_ref().and_then(|a| a.report.as_ref());
                    let a_length = current.as_ref().map_or(0, |a| a.deck.end_ms());
                    let next_length = request.analysis.samples.div_ceil(48);
                    let transition = analysis::plan(
                        &settings,
                        a_report,
                        &request.analysis,
                        a_length,
                        next_length,
                        current.as_ref().map_or(1., |a| a.deck.timescale.speed),
                    );
                    request.open.position = transition.cue_in_ms;
                    request.open.tempo_multiplier = transition.tempo_multiplier;
                    let cfg = settings.clone();
                    let bg_wire = wire.clone();
                    let bg_running = running.clone();
                    let bg_control = control.clone();
                    let slot = slots[request.slot as usize].clone();
                    let cancel = Arc::new(AtomicBool::new(false));
                    let bg_cancel = cancel.clone();
                    let (sender, received) = mpsc::sync_channel(1);
                    let tag = request.tag;
                    let slot_id = request.slot;
                    let thread = std::thread::spawn(move || {
                        let result = (|| {
                            let deck = Deck::open(
                                &request.open,
                                source(&request.open, &bg_wire, slot, bg_running, bg_cancel),
                            )?;
                            let mut cursor =
                                Cursor::new(tag, slot_id, deck, Some(request.analysis), &cfg)?;
                            if cursor.frame.is_none() {
                                return Err("next track has no audio".into());
                            }
                            cursor.multiplier = transition.tempo_multiplier;
                            Ok::<_, AudioError>((cursor, transition))
                        })()
                        .map_err(|error| error.to_string());
                        let _ = sender.send(result);
                        if let Ok(mut state) = bg_control.0.lock() {
                            state.revision = state.revision.wrapping_add(1);
                        }
                        bg_control.1.notify_all();
                    });
                    opening = Some(Opening {
                        tag,
                        slot: slot_id,
                        cancel,
                        settings: settings.clone(),
                        received,
                        thread,
                    });
                }
                Command::Cancel(tag) => {
                    if fade.is_some() && next.as_ref().is_some_and(|b| b.tag == tag) {
                        event(
                            &wire,
                            json!({"type":"cancelRejected","tag":tag,"message":"Transition already rendered"}),
                        )?;
                    } else {
                        if let Some(b) = next.take() {
                            if b.tag == tag {
                                event(
                                    &wire,
                                    json!({"type":"sourceRetired","tag":tag,"slot":b.slot,"cancelled":true}),
                                )?;
                                plan = None;
                            } else {
                                next = Some(b);
                            }
                        }
                        if let Some(job) = &opening {
                            if job.tag == tag {
                                job.cancel.store(true, Ordering::Release);
                            }
                        }
                    }
                }
                Command::Settings(value) => {
                    if value.valid() {
                        settings = value;
                        if let Some(a) = &mut current {
                            a.gain = settings.gain(a.report.as_ref());
                        }
                        if let Some(b) = &mut next {
                            b.gain = settings.gain(b.report.as_ref());
                        }
                        event(
                            &wire,
                            json!({"type":"settingsApplied", "deferredTransition":next.is_some() || opening.is_some() || fade.is_some()}),
                        )?;
                    }
                }
                Command::Skip => {
                    if let (Some(a), Some(p)) = (&current, &mut plan) {
                        p.start_ms = a.position;
                    }
                }
            }
        }
        if let Some(job) = &opening {
            match job.received.try_recv() {
                Ok(result) => {
                    let job = opening.take().ok_or("opening invariant")?;
                    let _ = job.thread.join();
                    if job.cancel.load(Ordering::Acquire) {
                        event(
                            &wire,
                            json!({"type":"sourceRetired","tag":job.tag,"slot":job.slot,"cancelled":true}),
                        )?;
                    } else {
                        match result {
                            Ok((mut cursor, transition)) => {
                                cursor.gain = settings.gain(cursor.report.as_ref());
                                event(
                                    &wire,
                                    json!({"type":"nextReady","tag":job.tag,"slot":job.slot,"plan":transition,"settings":job.settings}),
                                )?;
                                next = Some(cursor);
                                plan = Some(transition);
                            }
                            Err(message) => {
                                event(
                                    &wire,
                                    json!({"type":"prepareFailed","tag":job.tag,"slot":job.slot,"message":message.chars().take(256).collect::<String>()}),
                                )?;
                            }
                        }
                    }
                }
                Err(mpsc::TryRecvError::Empty) => (),
                Err(_) => return Err("next decoder thread failed".into()),
            }
        }
        if current.is_none() && next.is_some() {
            current = next.take();
            plan = None;
            if let Some(a) = &current {
                event(
                    &wire,
                    json!({"type":"transitionStarted","tag":a.tag,"slot":a.slot,"gapless":true}),
                )?;
            }
        }
        if !can_render || current.is_none() {
            let state = control.0.lock().map_err(|_| "control lock poisoned")?;
            if running.load(Ordering::Acquire) && state.revision == revision {
                drop(control.1.wait(state).map_err(|_| "control lock poisoned")?);
            }
            continue;
        }
        let mut samples = [0.; 1920];
        let mut valid = 0usize;
        let mut tag = current.as_ref().map_or(open.tag, |a| a.tag);
        let mut position = 0u64;
        for output in samples.chunks_exact_mut(2) {
            if fade.is_none()
                && next.is_some()
                && plan
                    .as_ref()
                    .is_some_and(|p| current.as_ref().is_some_and(|a| a.position >= p.start_ms))
            {
                let p = plan.as_mut().ok_or("transition plan invariant")?;
                if let Some(a) = &current {
                    let remaining = ((a.deck.end_ms() as f64 - a.position).max(0.) * 48.
                        / a.deck.timescale.speed)
                        .ceil() as u64;
                    if p.fade_samples > remaining {
                        p.fade_samples = remaining;
                        p.mode = if remaining == 0 {
                            "gapless"
                        } else {
                            "crossfade"
                        };
                        p.start_ms = a.position;
                    }
                }
                if p.fade_samples > 0 {
                    fade = Some((0, p.fade_samples));
                    if let Some(b) = &next {
                        event(
                            &wire,
                            json!({"type":"transitionStarted","tag":b.tag,"slot":b.slot,"plan":p}),
                        )?;
                    }
                } else {
                    if let Some(a) = current.take() {
                        event(
                            &wire,
                            json!({"type":"sourceRetired","tag":a.tag,"slot":a.slot}),
                        )?;
                    }
                    current = next.take();
                    plan = None;
                    if let Some(a) = &current {
                        event(
                            &wire,
                            json!({"type":"transitionStarted","tag":a.tag,"slot":a.slot,"gapless":true}),
                        )?;
                    }
                }
            }
            if let Some((progress, total)) = &mut fade {
                let a = current.as_mut().ok_or("outgoing deck invariant")?;
                let b = next.as_mut().ok_or("incoming deck invariant")?;
                let left = a.sample()?.unwrap_or([0.; 2]);
                let right = b.sample()?.unwrap_or([0.; 2]);
                let angle = *progress as f64 / (*total).max(1) as f64 * std::f64::consts::FRAC_PI_2;
                let (gb, ga) = angle.sin_cos();
                let ga = ga as f32;
                let gb = gb as f32;
                output
                    .copy_from_slice(&[left[0] * ga + right[0] * gb, left[1] * ga + right[1] * gb]);
                tag = b.tag;
                position = b.position.round() as u64;
                *progress += 1;
                valid += 1;
                if *progress >= *total {
                    if let Some(a) = current.take() {
                        event(
                            &wire,
                            json!({"type":"sourceRetired","tag":a.tag,"slot":a.slot}),
                        )?;
                    }
                    current = next.take();
                    fade = None;
                    plan = None;
                    if let Some(b) = &current {
                        if b.multiplier != 1. {
                            ramp = Some((b.multiplier, 0, 48_000 * 4));
                        }
                    }
                }
            } else {
                while let Some(a) = &mut current {
                    if let Some(sample) = a.sample()? {
                        output.copy_from_slice(&sample);
                        tag = a.tag;
                        position = a.position.round() as u64;
                        valid += 1;
                        break;
                    }
                    let a = current.take().ok_or("finished deck invariant")?;
                    event(
                        &wire,
                        json!({"type":"ended","tag":a.tag,"slot":a.slot,"afterFrame":ordinal + u64::from(valid > 0)}),
                    )?;
                    event(
                        &wire,
                        json!({"type":"sourceRetired","tag":a.tag,"slot":a.slot}),
                    )?;
                    current = next.take();
                    plan = None;
                    if let Some(a) = &current {
                        event(
                            &wire,
                            json!({"type":"transitionStarted","tag":a.tag,"slot":a.slot,"gapless":true}),
                        )?;
                    }
                }
                if current.is_none() {
                    break;
                }
            }
        }
        if valid == 0 {
            continue;
        }
        for frame in samples[..valid * 2].chunks_exact_mut(2) {
            let mut stereo = [frame[0], frame[1]];
            if settings.sound_check || settings.auto_mix {
                dsp.process_mix(&mut stereo, gain);
            } else {
                dsp.process(&mut stereo, gain);
            }
            frame.copy_from_slice(&stereo);
        }
        if settings.sound_check || settings.auto_mix {
            limiter.process(&mut samples[..valid * 2], settings.peak_ceiling_db)?;
        }
        let mut payload = [0; 1042];
        let bytes = encoder.encode_float(&samples, &mut payload[18..])?;
        payload[..8].copy_from_slice(&tag.to_be_bytes());
        payload[8..16].copy_from_slice(&position.to_be_bytes());
        payload[16..18].copy_from_slice(&(valid as u16).to_be_bytes());
        wire.send(16, 0, &payload[..18 + bytes])?;
        control
            .0
            .lock()
            .map_err(|_| "control lock poisoned")?
            .emitted += 1;
        if let Some((initial, done, total)) = &mut ramp {
            *done = (*done + valid as u64).min(*total);
            let multiplier = 1. + (*initial - 1.) * (1. - *done as f64 / *total as f64);
            if let Some(a) = &mut current {
                a.deck.set_multiplier(multiplier)?;
                a.multiplier = multiplier;
            }
            if *done >= *total {
                ramp = None;
            }
        }
    }
    if let Some(job) = opening {
        job.cancel.store(true, Ordering::Release);
        let _ = job.thread.join();
    }
    Ok(())
}
