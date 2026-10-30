defmodule Lixi.Voice.EDA do
  @moduledoc "Headless EDA Voice integration for Lavalink sessions; never starts a main Gateway."
  use WebSockex
  alias EDA.Voice.{Crypto, Payload}
  alias EDA.Voice.Dave.{Manager, Native}
  alias Lixi.Voice.Packet

  def start(owner, user, guild, voice) do
    with true <- Native.available?(),
         {:ok, url} <- endpoint(voice["endpoint"]),
         :ok <- claim_voice(user, guild) do
      state = %{
        owner: owner,
        claimed: false,
        monitor: nil,
        user: user,
        guild: guild,
        voice: voice,
        socket: nil,
        transport: nil,
        packet: Packet.new(),
        manager: nil,
        ready: false,
        epoch: 0,
        seq: -1,
        seen: MapSet.new(),
        seen_order: :queue.new(),
        pending_transition: false,
        heartbeat: nil,
        heartbeat_ack: true,
        heartbeat_sent: nil,
        ping: -1,
        clients: MapSet.new(),
        reconnecting: false,
        retries: 0,
        silence: nil
      }

      WebSockex.start(url, __MODULE__, state, handle_initial_conn_failure: true)
    else
      false -> {:error, :dave_unavailable}
      error -> error
    end
  end

  defp claim_voice(user, guild) do
    case Registry.register(Lixi.Registry, {:voice, user, guild}, nil) do
      {:ok, _} -> claim_global(user, guild)
      {:error, {:already_registered, pid}} when pid == self() -> claim_global(user, guild)
      _ -> {:error, :voice_already_owned}
    end
  end

  defp claim_global(user, guild) do
    case Lixi.Cluster.claim({:voice, user, guild}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def send_frame(pid, frame, epoch, due), do: request(pid, {:frame, frame, epoch, due})
  def fence(pid, epoch), do: request(pid, {:fence, epoch})
  def resume(pid), do: request(pid, :resume)
  def quiesce(pid), do: request(pid, :quiesce)
  def close(pid) when is_pid(pid), do: WebSockex.cast(pid, :shutdown)
  def close(_), do: :ok

  defp request(pid, command) do
    ref = Process.monitor(pid)
    WebSockex.cast(pid, {:request, self(), ref, command})

    result =
      receive do
        {:voice_reply, ^ref, result} -> result
        {:DOWN, ^ref, :process, ^pid, _} -> {:error, :closed}
      after
        2_000 ->
          close(pid)
          {:error, :timeout}
      end

    Process.demonitor(ref, [:flush])
    result
  end

  defp endpoint(value) when is_binary(value) do
    uri = URI.parse(if String.starts_with?(value, "wss://"), do: value, else: "wss://" <> value)

    if uri.scheme == "wss" and is_binary(uri.host) and is_nil(uri.userinfo) and
         Enum.any?(
           [".discord.media", ".discord.gg", ".discord.com"],
           &String.ends_with?(uri.host, &1)
         ) do
      {:ok, URI.to_string(%{uri | path: "/", query: "v=8", fragment: nil})}
    else
      {:error, :invalid_voice_endpoint}
    end
  end

  defp endpoint(_), do: {:error, :invalid_voice_endpoint}

  @impl true
  def handle_connect(_, %{claimed: false} = state) do
    state = %{state | monitor: Process.monitor(state.owner)}

    case Lixi.Cluster.move({:voice, state.user, state.guild}, state.owner, self()) do
      :ok ->
        Registry.register(Lixi.Registry, {:voice_sender, state.user, state.guild}, nil)
        {:ok, %{state | claimed: true}}

      _ ->
        send(self(), :ownership_rejected)
        {:ok, state}
    end
  end

  def handle_connect(_, state), do: {:ok, state}

  @impl true
  def handle_frame(_, %{claimed: false} = state),
    do: {:close, {4000, "Voice ownership unavailable"}, state}

  def handle_frame({:text, text}, state) when byte_size(text) <= 1_048_576 do
    case Jason.decode(text) do
      {:ok, %{"op" => op, "d" => data} = message} ->
        numbered(op, data, message["seq"], state)

      _ ->
        {:close, {4002, "Invalid voice payload"}, state}
    end
  end

  def handle_frame({:binary, <<seq::16, op, data::binary>>}, state)
      when byte_size(data) <= 1_048_576 do
    data =
      case {op, data} do
        {25, bytes} ->
          %{"external_sender_bin" => bytes}

        {27, <<kind, bytes::binary>>} ->
          %{
            "operation_type" => kind,
            "proposals_bin" => bytes,
            "connected_clients" => state.clients
          }

        {29, <<id::16, bytes::binary>>} ->
          %{"transition_id" => id, "commit_bin" => bytes}

        {30, <<id::16, bytes::binary>>} ->
          %{"transition_id" => id, "welcome_bin" => bytes}

        _ ->
          nil
      end

    if data, do: numbered(op, data, seq, state), else: {:ok, state}
  end

  def handle_frame(_, state), do: {:ok, state}

  defp numbered(op, data, nil, state), do: dispatch(op, data, state)

  defp numbered(op, data, seq, state) when is_integer(seq) and seq in 0..65_535 do
    if MapSet.member?(state.seen, seq) do
      {:ok, state}
    else
      seen = MapSet.put(state.seen, seq)
      order = :queue.in(seq, state.seen_order)

      {seen, order} =
        if MapSet.size(seen) > 128 do
          {{:value, old}, order} = :queue.out(order)
          {MapSet.delete(seen, old), order}
        else
          {seen, order}
        end

      dispatch(op, data, %{state | seq: seq, seen: seen, seen_order: order})
    end
  end

  defp numbered(_, _, _, state), do: {:close, {4002, "Invalid voice sequence"}, state}

  defp dispatch(8, %{"heartbeat_interval" => interval}, state)
       when is_number(interval) and interval >= 100 do
    if state.heartbeat, do: Process.cancel_timer(state.heartbeat)
    timer = Process.send_after(self(), {:heartbeat, make_ref()}, trunc(interval))

    message =
      if state.reconnecting do
        Payload.resume(state.guild, state.voice["sessionId"], state.voice["token"])
        |> put_in([:d, :seq_ack], state.seq)
      else
        Payload.identify(
          state.guild,
          state.user,
          state.voice["sessionId"],
          state.voice["token"],
          Native.max_protocol_version()
        )
      end

    reply(
      message,
      %{state | heartbeat: timer, heartbeat_ack: true} |> Map.put(:interval, trunc(interval))
    )
  end

  defp dispatch(2, %{"ip" => ip, "port" => port, "ssrc" => ssrc, "modes" => modes}, state) do
    with {:ok, mode} <- Crypto.select_mode(modes),
         {:ok, address} <- :inet.parse_address(String.to_charlist(ip)),
         {:ok, socket} <- :gen_udp.open(0, [:binary, active: :once]) do
      if state.socket, do: :gen_udp.close(state.socket)
      packet = <<1::16, 70::16, ssrc::32, 0::512, 0::16>>
      :ok = :gen_udp.send(socket, address, port, packet)
      Process.send_after(self(), {:discovery_timeout, socket}, 5_000)

      {:ok,
       %{
         state
         | socket: socket,
           transport: %{ip: address, port: port, ssrc: ssrc, mode: mode, key: nil}
       }}
    else
      _ -> {:close, {4002, "Voice UDP negotiation failed"}, state}
    end
  end

  defp dispatch(4, data, %{transport: transport} = state) when is_map(transport) do
    version = data["dave_protocol_version"] || get_in(data, ["dave", "protocol_version"]) || 0
    key = data["secret_key"]

    if is_integer(version) and version > 0 and is_list(key) and length(key) == 32 and
         Enum.all?(key, &(&1 in 0..255)) do
      install_crypto(state, version, :erlang.list_to_binary(key))
    else
      {:close, {4017, "DAVE required"}, state}
    end
  end

  defp dispatch(6, _, state) do
    ping =
      if state.heartbeat_sent,
        do: System.monotonic_time(:millisecond) - state.heartbeat_sent,
        else: -1

    send(state.owner, {:voice, self(), {:ping, ping}})
    {:ok, %{state | heartbeat_ack: true, ping: ping}}
  end

  defp dispatch(9, _, state) do
    ready =
      not state.pending_transition and state.manager != nil and Manager.ready?(state.manager)

    if ready, do: send(state.owner, {:voice, self(), :ready})
    {:ok, %{state | reconnecting: false, retries: 0, ready: ready}}
  end

  defp dispatch(11, %{"user_ids" => ids}, state),
    do: {:ok, %{state | clients: Enum.reduce(ids, state.clients, &MapSet.put(&2, to_string(&1)))}}

  defp dispatch(13, %{"user_id" => id}, state),
    do: {:ok, %{state | clients: MapSet.delete(state.clients, to_string(id))}}

  defp dispatch(op, data, %{manager: %Manager{} = manager} = state) when op in 21..31 do
    # davey 0.1 mutates sender state during commit preparation. Keep the gate
    # closed until Execute rather than sending with a prepared, uncommitted key.
    if op != 22, do: send(state.owner, {:voice, self(), :buffering})
    if op == 21, do: Lixi.Metrics.record(:dave_transitions)
    {manager, payloads} = Manager.handle_mls_event(manager, op, data)
    ready = (op == 22 or data["transition_id"] == 0) and Manager.ready?(manager)

    if ready do
      Lixi.Metrics.record(:dave_ready)
      send(state.owner, {:voice, self(), :ready})
    end

    Enum.each(payloads, &send(self(), {:outbound, &1}))
    {:ok, %{state | manager: manager, ready: ready, pending_transition: not ready}}
  end

  defp dispatch(_, _, state), do: {:ok, state}

  defp install_crypto(state, version, key) do
    fingerprint = :crypto.hash(:sha256, key)

    permission =
      Lixi.Cluster.remember_key(
        {:voice, state.user, state.guild},
        self(),
        self(),
        fingerprint
      )

    if state.voice[:previous_key_fingerprint] == fingerprint or permission != :ok do
      {:close, {4006, "Fresh transport key required"}, state}
    else
      send(state.owner, {:voice, self(), {:key_fingerprint, fingerprint}})

      manager =
        Manager.new(
          version,
          String.to_integer(state.user),
          String.to_integer(state.voice["channelId"])
        )

      state = %{
        state
        | transport: %{state.transport | key: key},
          manager: manager,
          ready: false
      }

      case Manager.key_package_payload(manager) do
        {:ok, payload} -> reply(payload, state)
        _ -> {:close, {4017, "DAVE initialization failed"}, state}
      end
    end
  end

  @impl true
  def handle_cast({:request, owner, ref, command}, %{owner: owner} = state),
    do: command(command, ref, state)

  def handle_cast(:shutdown, state), do: {:close, state}
  def handle_cast(_, state), do: {:ok, state}

  defp command({:fence, epoch}, ref, state) do
    respond(state, ref, :ok)
    {:ok, %{state | epoch: epoch}}
  end

  defp command(:resume, ref, %{ready: true} = state) do
    respond(state, ref, :ok)
    reply(Payload.speaking(state.transport.ssrc, true), state)
  end

  defp command({:frame, frame, epoch, due}, ref, %{epoch: epoch, ready: true} = state) do
    if System.monotonic_time(:microsecond) - due >= 20_000 do
      respond(state, ref, {:error, :expired})
      {:ok, state}
    else
      {result, state} = transmit(state, frame.opus, due + 20_000)
      respond(state, ref, result)
      {:ok, state}
    end
  end

  defp command(:quiesce, ref, %{ready: true, silence: nil} = state) do
    send(self(), {:silence, ref})
    {:ok, %{state | silence: {ref, 5}}}
  end

  defp command(_, ref, state) do
    respond(state, ref, {:error, :not_ready})
    {:ok, state}
  end

  defp transmit(state, opus, deadline \\ :infinity) do
    encrypt = fn raw ->
      case Manager.encrypt_frame(state.manager, raw) do
        {:ok, encrypted, _} -> {:ok, encrypted}
        {:error, reason, _} -> {:error, reason}
      end
    end

    udp = fn packet ->
      if Process.alive?(state.owner) and
           (deadline == :infinity or System.monotonic_time(:microsecond) < deadline) do
        :gen_udp.send(state.socket, state.transport.ip, state.transport.port, packet)
      else
        {:error, :expired}
      end
    end

    case Packet.transmit(state.packet, opus, state.transport, encrypt, udp) do
      {:ok, packet} -> {:ok, %{state | packet: packet}}
      {:error, reason, packet} -> {{:error, reason}, %{state | packet: packet}}
    end
  end

  defp respond(state, ref, result), do: send(state.owner, {:voice_reply, ref, result})
  defp reply({:binary, _} = frame, state), do: {:reply, frame, state}
  defp reply(payload, state), do: {:reply, {:text, Jason.encode!(payload)}, state}

  @impl true
  def handle_info(:ownership_rejected, state),
    do: {:close, {4000, "Voice ownership unavailable"}, state}

  def handle_info({:outbound, payload}, state), do: reply(payload, state)

  def handle_info({:heartbeat, _}, state) do
    if state.heartbeat_ack do
      now = System.monotonic_time(:millisecond)
      timer = Process.send_after(self(), {:heartbeat, make_ref()}, state.interval)

      reply(Payload.heartbeat(now, state.seq), %{
        state
        | heartbeat: timer,
          heartbeat_ack: false,
          heartbeat_sent: now
      })
    else
      {:close, {4000, "Heartbeat timeout"}, state}
    end
  end

  def handle_info(
        {:udp, socket, address, port,
         <<2::16, 70::16, ssrc::32, ip::binary-size(64), external_port::16>>},
        %{socket: socket, transport: %{ip: address, port: port, ssrc: ssrc}} = state
      ) do
    :inet.setopts(socket, active: :once)

    reply(
      Payload.select_protocol(
        String.trim_trailing(ip, <<0>>),
        external_port,
        state.transport.mode
      ),
      state
    )
  end

  def handle_info({:udp, socket, _, _, _}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {:ok, state}
  end

  def handle_info(
        {:discovery_timeout, socket},
        %{socket: socket, transport: %{key: nil}} = state
      ),
      do: {:close, {4000, "IP discovery timed out"}, state}

  def handle_info({:silence, ref}, %{silence: {ref, 0}} = state) do
    respond(state, ref, :ok)
    reply(Payload.speaking(state.transport.ssrc, false), %{state | silence: nil})
  end

  def handle_info({:silence, ref}, %{silence: {ref, remaining}, ready: true} = state) do
    {result, state} = transmit(state, <<0xF8, 0xFF, 0xFE>>)

    if result == :ok do
      Process.send_after(self(), {:silence, ref}, 20)
      {:ok, %{state | silence: {ref, remaining - 1}}}
    else
      respond(state, ref, result)
      {:ok, %{state | silence: nil}}
    end
  end

  def handle_info({:silence, ref}, state) do
    respond(state, ref, {:error, :not_ready})
    {:ok, %{state | silence: nil}}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{monitor: ref} = state), do: {:close, state}
  def handle_info(_, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    if state.heartbeat, do: Process.cancel_timer(state.heartbeat)
    send(state.owner, {:voice, self(), :buffering})

    fatal =
      case reason do
        {:remote, code, _} -> code in [4004, 4006, 4011, 4012, 4014, 4015, 4016, 4017]
        _ -> false
      end

    if (not fatal and state.retries < 3 and state.transport) && state.transport.key do
      Lixi.Metrics.record(:voice_reconnects)
      {:reconnect, %{state | ready: false, reconnecting: true, retries: state.retries + 1}}
    else
      send(
        state.owner,
        {:voice, self(), {:closed, close_code(reason), "Voice connection closed", true}}
      )

      {:ok, state}
    end
  end

  defp close_code({:remote, code, _}), do: code
  defp close_code(_), do: 1006
  @impl true
  def terminate(_, state) do
    if state.socket, do: :gen_udp.close(state.socket)
    if state.heartbeat, do: Process.cancel_timer(state.heartbeat)
  end
end
