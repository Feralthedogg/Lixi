defmodule Lixi.VoiceTest do
  use ExUnit.Case, async: true
  alias Lixi.Voice.Packet

  test "EDA native DAVE is available and an unready group cannot send plaintext" do
    assert EDA.Voice.Dave.Native.available?()
    manager = EDA.Voice.Dave.Manager.new(1, 123, 789)
    assert is_reference(manager.mls_session)
    refute EDA.Voice.Dave.Manager.ready?(manager)

    assert {:error, :not_ready, _} =
             EDA.Voice.Dave.Manager.encrypt_frame(manager, <<0xF8, 0xFF, 0xFE>>)
  end

  test "both EDA transport modes round trip over a real UDP socket" do
    {:ok, receiver} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(receiver)
    {:ok, sender} = :gen_udp.open(0, [:binary, active: false])

    on_exit(fn ->
      :gen_udp.close(receiver)
      :gen_udp.close(sender)
    end)

    for mode <- ["aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"] do
      key = :crypto.strong_rand_bytes(32)
      transport = %{ssrc: 456, key: key, mode: mode}
      send_packet = &:gen_udp.send(sender, {127, 0, 0, 1}, port, &1)

      assert {:ok, next} =
               Packet.transmit(Packet.new(), <<1, 2, 3>>, transport, &{:ok, &1}, send_packet)

      assert next.nonce == 1
      assert {:ok, {_, _, bytes}} = :gen_udp.recv(receiver, 0, 1000)
      assert {:ok, <<1, 2, 3>>} = EDA.Voice.Crypto.decrypt_packet(bytes, key, mode)
    end
  end

  test "UDP and encryption failures consume nonce and sequence reservations" do
    transport = %{ssrc: 456, key: :crypto.strong_rand_bytes(32), mode: "aead_aes256_gcm_rtpsize"}
    initial = %Packet{origin: 0}

    assert {:error, :closed, state} =
             Packet.transmit(
               initial,
               <<1>>,
               transport,
               &{:ok, &1},
               fn _ -> {:error, :closed} end,
               0
             )

    assert state.nonce == 1 and state.sequence == 1

    assert {:error, :not_ready, next} =
             Packet.transmit(
               state,
               <<1>>,
               transport,
               fn _ -> {:error, :not_ready} end,
               fn _ -> flunk("must not send") end,
               20_000
             )

    assert next.nonce == 2 and next.sequence == 2
    exhausted = %{next | nonce: 0x100000000}

    assert {:error, :nonce_exhausted, ^exhausted} =
             Packet.transmit(exhausted, <<1>>, transport, &{:ok, &1}, fn _ ->
               flunk("must not send")
             end)
  end
end
