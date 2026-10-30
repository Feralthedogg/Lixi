use crate::protocol::Wire;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc::Receiver,
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use symphonia::core::io::MediaSource;

type Responses = Arc<Mutex<Receiver<(u64, Vec<u8>)>>>;

#[derive(Clone)]
pub struct Slot {
    index: u8,
    responses: Responses,
    next_read: Arc<AtomicU64>,
}
impl Slot {
    pub fn new(index: u8, responses: Receiver<(u64, Vec<u8>)>) -> Self {
        Self {
            index,
            responses: Arc::new(Mutex::new(responses)),
            next_read: Arc::new(AtomicU64::new(0)),
        }
    }
}

pub struct Source {
    pub length: u64,
    pub position: u64,
    pub wire: Wire,
    slot: Slot,
    cancelled: Arc<AtomicBool>,
    pub running: Arc<AtomicBool>,
}

impl Source {
    pub fn with_slot(
        length: u64,
        wire: Wire,
        slot: Slot,
        running: Arc<AtomicBool>,
        cancelled: Arc<AtomicBool>,
    ) -> Self {
        Self {
            length,
            position: 0,
            wire,
            slot,
            running,
            cancelled,
        }
    }
    fn alive(&self) -> bool {
        self.running.load(Ordering::Acquire) && !self.cancelled.load(Ordering::Acquire)
    }
}

impl Read for Source {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let length = buffer
            .len()
            .min(65_536)
            .min(self.length.saturating_sub(self.position) as usize);
        if length == 0 {
            return Ok(0);
        }
        if !self.alive() {
            return Err(io::ErrorKind::Interrupted.into());
        }
        let counter = self.slot.next_read.fetch_add(1, Ordering::AcqRel) + 1;
        if counter >= (1u64 << 63) {
            return Err(io::Error::other("source request counter exhausted"));
        }
        let request_id = (u64::from(self.slot.index) << 63) | counter;
        let mut request = [0; 12];
        request[..8].copy_from_slice(&self.position.to_be_bytes());
        request[8..].copy_from_slice(&(length as u32).to_be_bytes());
        self.wire.send(3, request_id, &request)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        let receiver = self
            .slot
            .responses
            .lock()
            .map_err(|_| io::Error::other("source lock poisoned"))?;
        let (id, packet) = loop {
            if !self.alive() {
                return Err(io::ErrorKind::Interrupted.into());
            }
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok((id, _)) if id < request_id => continue,
                Ok(response) => break response,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) if Instant::now() < deadline => {
                    continue
                }
                Err(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "source read timed out",
                    ))
                }
            }
        };
        let bytes = packet
            .get(crate::protocol::HEADER..)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "short source response"))?;
        if id != request_id || bytes.len() > length || bytes.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid source response",
            ));
        }
        buffer[..bytes.len()].copy_from_slice(bytes);
        self.position += bytes.len() as u64;
        self.wire.send(8, id, &[])?;
        Ok(bytes.len())
    }
}

impl Seek for Source {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let position = match from {
            SeekFrom::Start(n) => i128::from(n),
            SeekFrom::Current(n) => i128::from(self.position) + i128::from(n),
            SeekFrom::End(n) => i128::from(self.length) + i128::from(n),
        };
        if position < 0 || position > i128::from(self.length) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek out of bounds",
            ));
        }
        self.position = position as u64;
        Ok(self.position)
    }
}

impl MediaSource for Source {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        Some(self.length)
    }
}
