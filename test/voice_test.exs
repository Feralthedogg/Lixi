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

  test "early MLS events are retained before session description and bounded" do
    state = %{
      claimed: true,
      manager: nil,
      seq: -1,
      seen: MapSet.new(),
      seen_order: :queue.new(),
      early_mls: :queue.new(),
      early_mls_bytes: 0
    }

    assert {:ok, queued} = Lixi.Voice.EDA.handle_frame({:binary, <<0::16, 25, 1, 2, 3>>}, state)
    assert [{25, %{"external_sender_bin" => <<1, 2, 3>>}}] = :queue.to_list(queued.early_mls)
    assert queued.seq == 0
    assert {:ok, ^queued} = Lixi.Voice.EDA.handle_frame({:binary, <<0::16, 25, 1, 2, 3>>}, queued)
    full = %{queued | early_mls_bytes: 1_048_576}
    assert {:close, {4002, _}, _} = Lixi.Voice.EDA.handle_frame({:binary, <<1::16, 25, 1>>}, full)
  end

  test "epoch one reinitialization closes the media gate and preserves RTP nonce" do
    manager = EDA.Voice.Dave.Manager.new(1, 123, 789)
    packet = %Packet{nonce: 7}

    state = %{
      claimed: true,
      owner: self(),
      manager: manager,
      packet: packet,
      ready: true,
      pending_transition: false,
      seq: 0,
      seen: MapSet.new(),
      seen_order: :queue.new()
    }

    frame = Jason.encode!(%{op: 24, seq: 1, d: %{epoch: 1, protocol_version: 1}})
    assert {:ok, next} = Lixi.Voice.EDA.handle_frame({:text, frame}, state)
    refute next.ready
    assert next.pending_transition
    assert next.packet == packet
    refute EDA.Voice.Dave.Manager.ready?(next.manager)
    assert_receive {:outbound, {:binary, <<26, payload::binary>>}} when byte_size(payload) > 0
  end

  test "session description waits for external sender before sending a key package" do
    user = "901"
    guild = to_string(System.unique_integer([:positive]))
    {:ok, _} = Lixi.Cluster.claim({:voice, user, guild})

    state = %{
      claimed: true,
      user: user,
      guild: guild,
      owner: self(),
      manager: nil,
      voice: %{"channelId" => "789"},
      transport: %{key: nil},
      ready: false,
      early_mls: :queue.new(),
      early_mls_bytes: 0
    }

    frame =
      Jason.encode!(%{
        op: 4,
        d: %{
          dave_protocol_version: 1,
          secret_key: :crypto.strong_rand_bytes(32) |> :binary.bin_to_list()
        }
      })

    assert {:ok, next} = Lixi.Voice.EDA.handle_frame({:text, frame}, state)
    assert is_reference(next.manager.mls_session)
    refute next.ready
    refute_receive {:outbound, {:binary, <<26, _::binary>>}}, 20
    Lixi.Cluster.release({:voice, user, guild})
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

  test "RTP timestamps count samples without holes from dispatch jitter" do
    transport = %{ssrc: 456, key: :crypto.strong_rand_bytes(32), mode: "aead_aes256_gcm_rtpsize"}

    sender = fn <<_::32, timestamp::32, _::binary>> ->
      send(self(), {:rtp_time, timestamp})
      :ok
    end

    Enum.reduce([19_000, 41_000, 60_000, 81_000], %Packet{}, fn now, state ->
      {:ok, next} = Packet.transmit(state, <<1>>, transport, &{:ok, &1}, sender, now)
      next
    end)

    for timestamp <- [0, 960, 1920, 2880], do: assert_receive({:rtp_time, ^timestamp})
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
