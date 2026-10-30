use std::sync::Mutex;
use symphonia::core::{
    audio::{AsAudioBufferRef, AudioBuffer, AudioBufferRef, Signal, SignalSpec},
    codecs::{
        CodecDescriptor, CodecParameters, Decoder, DecoderOptions, FinalizeResult, CODEC_TYPE_OPUS,
    },
    errors::{decode_error, unsupported_error, Error, Result},
    formats::Packet,
    support_codec,
};

/// Mapping family 0 mono/stereo; the demuxer owns codec delay and packet trims.
pub struct OpusDecoder {
    decoder: Mutex<opus::Decoder>,
    params: CodecParameters,
    samples: Vec<f32>,
    buffer: AudioBuffer<f32>,
}

impl Decoder for OpusDecoder {
    fn try_new(params: &CodecParameters, _: &DecoderOptions) -> Result<Self> {
        let header = params.extra_data.as_deref().unwrap_or(&[]);
        if header.len() != 19 || &header[..8] != b"OpusHead" || header[8] != 1 || header[18] != 0 {
            return unsupported_error("Opus: expected version 1 mapping family 0 header");
        }
        let channels = match header[9] {
            1 => opus::Channels::Mono,
            2 => opus::Channels::Stereo,
            _ => return unsupported_error("Opus: only mono/stereo supported"),
        };
        let layout = params
            .channels
            .ok_or(Error::DecodeError("Opus: missing channel layout"))?;
        if layout.count() != usize::from(header[9]) {
            return decode_error("Opus: channel count mismatch");
        }
        let mut decoder = opus::Decoder::new(48_000, channels)
            .map_err(|_| Error::DecodeError("Opus: decoder initialization failed"))?;
        decoder
            .set_gain(i32::from(i16::from_le_bytes([header[16], header[17]])))
            .map_err(|_| Error::DecodeError("Opus: invalid output gain"))?;
        Ok(Self {
            decoder: Mutex::new(decoder),
            params: params.clone(),
            samples: vec![0.; 5760 * layout.count()],
            buffer: AudioBuffer::new(5760, SignalSpec::new(48_000, layout)),
        })
    }

    fn supported_codecs() -> &'static [CodecDescriptor] {
        &[support_codec!(CODEC_TYPE_OPUS, "opus", "Opus")]
    }
    fn reset(&mut self) {
        // This mutex only supplies Sync to Symphonia's trait; decode has exclusive ownership.
        if let Ok(decoder) = self.decoder.get_mut() {
            let _ = decoder.reset_state();
        }
        self.buffer.clear();
    }
    fn codec_params(&self) -> &CodecParameters {
        &self.params
    }
    fn decode(&mut self, packet: &Packet) -> Result<AudioBufferRef<'_>> {
        self.buffer.clear();
        let decoder = self
            .decoder
            .get_mut()
            .map_err(|_| Error::DecodeError("Opus: decoder lock poisoned"))?;
        let count = decoder
            .decode_float(&packet.data, &mut self.samples, false)
            .map_err(|_| Error::DecodeError("Opus: invalid packet"))?;
        let start = packet.trim_start() as usize;
        let end = packet.trim_end() as usize;
        if start + end > count {
            return decode_error("Opus: trim exceeds packet");
        }
        let valid = count - start - end;
        self.buffer.render_reserved(Some(valid));
        let channels = self.buffer.spec().channels.count();
        for channel in 0..channels {
            for (output, input) in self.buffer.chan_mut(channel).iter_mut().zip(
                self.samples[start * channels..(count - end) * channels].chunks_exact(channels),
            ) {
                *output = input[channel];
            }
        }
        Ok(self.buffer.as_audio_buffer_ref())
    }
    fn finalize(&mut self) -> FinalizeResult {
        FinalizeResult::default()
    }
    fn last_decoded(&self) -> AudioBufferRef<'_> {
        self.buffer.as_audio_buffer_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use symphonia::core::audio::Layout;

    fn params() -> CodecParameters {
        let mut header = b"OpusHead\x01\x02\x38\x01\x44\xac\x00\x00\x00\x00\x00".to_vec();
        header[16..18].copy_from_slice(&1536_i16.to_le_bytes());
        let mut params = CodecParameters::new();
        params
            .for_codec(CODEC_TYPE_OPUS)
            .with_sample_rate(48_000)
            .with_channels(Layout::Stereo.into_channels())
            .with_extra_data(header.into_boxed_slice());
        params
    }

    #[test]
    fn decoder_applies_packet_trims_once_and_clears_after_error() {
        let mut encoder =
            opus::Encoder::new(48_000, opus::Channels::Stereo, opus::Application::Audio).unwrap();
        let mut bytes = [0; 1024];
        let size = encoder.encode_float(&[0.1; 1920], &mut bytes).unwrap();
        let packet = Packet::new_trimmed_from_slice(1, 0, 624, 312, 24, &bytes[..size]);
        let mut decoder = OpusDecoder::try_new(&params(), &DecoderOptions::default()).unwrap();
        assert_eq!(decoder.decode(&packet).unwrap().frames(), 624);
        let invalid = Packet::new_trimmed_from_slice(1, 0, 0, 961, 0, &bytes[..size]);
        assert!(decoder.decode(&invalid).is_err());
        assert_eq!(decoder.last_decoded().frames(), 0);
        decoder.reset();
        assert_eq!(decoder.decode(&packet).unwrap().frames(), 624);
    }

    #[test]
    fn rejects_unsupported_mapping_and_malformed_headers() {
        let mut params = params();
        params.extra_data.as_mut().unwrap()[18] = 1;
        assert!(OpusDecoder::try_new(&params, &DecoderOptions::default()).is_err());
        params.extra_data = Some(Box::new([]));
        assert!(OpusDecoder::try_new(&params, &DecoderOptions::default()).is_err());
    }
}
