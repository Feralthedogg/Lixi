defmodule Lixi.Voice.Packet do
  @moduledoc "RTP reservation and nonce ownership. Failed sends consume their reservations."
  import Bitwise
  defstruct nonce: 0, sequence: 0, timestamp_base: 0, origin: 0, slot: -1

  def new do
    <<sequence::16, timestamp::32>> = :crypto.strong_rand_bytes(6)

    %__MODULE__{
      sequence: sequence,
      timestamp_base: timestamp,
      origin: System.monotonic_time(:microsecond)
    }
  end

  def transmit(
        state,
        opus,
        transport,
        encrypt,
        udp_send,
        _wall_time \\ nil
      ) do
    if state.nonce >= 0x100000000 do
      {:error, :nonce_exhausted, state}
    else
      # RTP counts encoded samples. Wall-clock buckets introduce audible holes
      # when small scheduling jitter crosses a bucket boundary.
      slot = state.slot + 1
      timestamp = state.timestamp_base + slot * 960 &&& 0xFFFFFFFF

      next = %{
        state
        | nonce: state.nonce + 1,
          sequence: state.sequence + 1 &&& 0xFFFF,
          slot: slot
      }

      with {:ok, encrypted} <- encrypt.(opus),
           packet <-
             EDA.Voice.Crypto.encrypt_packet(
               encrypted,
               state.sequence,
               timestamp,
               transport.ssrc,
               transport.key,
               transport.mode,
               state.nonce
             ),
           true <- byte_size(packet) <= 1200,
           :ok <- udp_send.(packet) do
        {:ok, next}
      else
        false -> {:error, :packet_too_large, next}
        {:error, reason} -> {:error, reason, next}
      end
    end
  end
end
