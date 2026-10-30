mod analysis;
mod deck;
mod dsp;
mod opus_decoder;
mod pcm;
mod protocol;
mod source;
mod swapping;
mod timescale;

use opus::{Application, Channels, Encoder};
use rubato::{FftFixedInOut, Resampler};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Condvar, Mutex,
};
use std::{collections::VecDeque, io};

#[derive(Clone, Deserialize)]
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
    #[serde(default)]
    swapping: Option<analysis::Settings>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    tag: u64,
    #[serde(default = "unity64")]
    tempo_multiplier: f64,
    #[serde(default)]
    report: Option<analysis::Report>,
}
fn unity64() -> f64 {
    1.
}
fn unity() -> f32 {
    1.0
}

struct Control {
    limit: u64,
    emitted: u64,
    gain: f32,
    commands: VecDeque<swapping::Command>,
    revision: u64,
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
    slots: [source::Slot; 2],
    running: Arc<AtomicBool>,
    control: Shared,
) -> Result<(), deck::AudioError> {
    if open
        .swapping
        .as_ref()
        .is_some_and(|settings| !settings.valid())
        || !(0.88..=1.12).contains(&open.tempo_multiplier)
    {
        return Err("invalid Swapping settings".into());
    }
    if open.mode.as_deref() == Some("prepare") {
        return swapping::prepare(open, wire, slots[0].clone(), running, control);
    }
    if open.swapping.is_some() {
        return swapping::render(open, wire, slots, running, control);
    }
    let source = source::Source::with_slot(
        open.length,
        wire.clone(),
        slots[0].clone(),
        running.clone(),
        Arc::new(AtomicBool::new(false)),
    );
    let mut deck = deck::Deck::open(&open, source)?;
    wire.send(2, 0, &serde_json::to_vec(&deck.metadata())?)?;
    let mut encoder = Encoder::new(48_000, Channels::Stereo, Application::Audio)?;
    encoder.set_bitrate(opus::Bitrate::Bits(96_000))?;
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
        let Some(mut frame) = deck.frame()? else {
            wire.send(6, 0, &[])?;
            break;
        };
        for sample in frame.samples[..frame.valid * 2].chunks_exact_mut(2) {
            let mut stereo = [sample[0], sample[1]];
            dsp.process(&mut stereo, gain);
            sample.copy_from_slice(&stereo);
        }
        let mut payload = [0; 1034];
        let bytes = encoder.encode_float(&frame.samples, &mut payload[10..])?;
        payload[..8].copy_from_slice(&frame.position.to_be_bytes());
        payload[8..10].copy_from_slice(&(frame.valid as u16).to_be_bytes());
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
fn main_result() -> Result<(), deck::AudioError> {
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
            commands: VecDeque::new(),
            revision: 0,
        }),
        Condvar::new(),
    ));
    let (responses_a, received_a) = mpsc::sync_channel(1);
    let (responses_b, received_b) = mpsc::sync_channel(1);
    let responses = [responses_a, responses_b];
    let slots = [
        source::Slot::new(0, received_a),
        source::Slot::new(1, received_b),
    ];
    let engine_control = control.clone();
    let engine_running = running.clone();
    let engine_wire = wire.clone();
    let engine = std::thread::spawn(move || {
        if let Err(err) = run(
            open,
            engine_wire.clone(),
            slots,
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
                let slot = (request >> 63) as usize;
                if packet.len() > 65_536 + 44 || responses[slot].send((request, packet)).is_err() {
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
                state.revision = state.revision.wrapping_add(1);
                control.1.notify_one();
            }
            11..=14 => {
                let command = match packet[1] {
                    11 => swapping::Command::Next(serde_json::from_slice(&packet[44..])?),
                    12 if packet.len() == 52 => {
                        swapping::Command::Cancel(u64::from_be_bytes(packet[44..52].try_into()?))
                    }
                    13 => swapping::Command::Settings(serde_json::from_slice(&packet[44..])?),
                    14 if packet.len() == 44 => swapping::Command::Skip,
                    _ => break,
                };
                let mut state = control.0.lock().map_err(|_| "control lock poisoned")?;
                if state.commands.len() >= 8 {
                    break;
                }
                state.commands.push_back(command);
                state.revision = state.revision.wrapping_add(1);
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
