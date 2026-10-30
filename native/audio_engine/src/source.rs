use crate::protocol::Wire;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::Receiver,
    Arc, Mutex,
};
use std::time::Duration;
use symphonia::core::io::MediaSource;

pub struct Source {
    pub length: u64,
    pub position: u64,
    pub wire: Wire,
    responses: Mutex<Receiver<(u64, Vec<u8>)>>,
    pub running: Arc<AtomicBool>,
    next_read: u64,
}

impl Source {
    pub fn new(
        length: u64,
        wire: Wire,
        responses: Receiver<(u64, Vec<u8>)>,
        running: Arc<AtomicBool>,
    ) -> Self {
        Self {
            length,
            position: 0,
            wire,
            responses: Mutex::new(responses),
            running,
            next_read: 0,
        }
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
        if !self.running.load(Ordering::Acquire) {
            return Err(io::ErrorKind::Interrupted.into());
        }
        self.next_read += 1;
        let mut request = [0; 12];
        request[..8].copy_from_slice(&self.position.to_be_bytes());
        request[8..].copy_from_slice(&(length as u32).to_be_bytes());
        self.wire.send(3, self.next_read, &request)?;
        let (id, packet) = self
            .responses
            .get_mut()
            .map_err(|_| io::Error::other("source lock poisoned"))?
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "source read timed out"))?;
        let bytes = packet
            .get(crate::protocol::HEADER..)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "short source response"))?;
        if id != self.next_read || bytes.len() > length || bytes.is_empty() {
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
