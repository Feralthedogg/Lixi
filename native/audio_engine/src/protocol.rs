use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};

pub const MAX_PACKET: usize = 131_072;
pub const HEADER: usize = 44;

#[derive(Clone)]
pub struct Wire {
    pub context: [u8; 40],
    output: Arc<Mutex<io::Stdout>>,
}

impl Wire {
    pub fn new(context: [u8; 40]) -> Self {
        Self {
            context,
            output: Arc::new(Mutex::new(io::stdout())),
        }
    }

    pub fn send(&self, kind: u8, request: u64, payload: &[u8]) -> io::Result<()> {
        if payload.len() + HEADER > MAX_PACKET {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "packet limit exceeded",
            ));
        }
        let mut output = self
            .output
            .lock()
            .map_err(|_| io::Error::other("stdout lock poisoned"))?;
        output.write_all(&((payload.len() + HEADER) as u32).to_be_bytes())?;
        output.write_all(&[1, kind, 0, 0])?;
        output.write_all(&self.context[..32])?;
        output.write_all(&request.to_be_bytes())?;
        output.write_all(payload)?;
        output.flush()
    }
}

pub fn read_packet(input: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut size = [0; 4];
    input.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if !(HEADER..=MAX_PACKET).contains(&size) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid packet size",
        ));
    }
    let mut body = vec![0; size];
    input.read_exact(&mut body)?;
    if body[0] != 1 || body[2..4] != [0, 0] {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported protocol",
        ));
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_length_before_allocating() {
        assert!(read_packet(&mut u32::MAX.to_be_bytes().as_slice()).is_err());
        assert!(read_packet(&mut 0_u32.to_be_bytes().as_slice()).is_err());
    }
}
