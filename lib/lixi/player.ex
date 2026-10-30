defmodule Lixi.Player do
  @moduledoc "Serializes commands, raw Opus ownership and the playback clock per guild."
  use GenServer, restart: :temporary
  alias Lixi.Audio.Worker

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def fetch_snapshot(pid) do
    case Lixi.Cluster.call(pid, :snapshot) do
      {:error, _} = error -> error
      value -> {:ok, value}
    end
  end

  def update(pid, patch, no_replace),
    do: Lixi.Cluster.call(pid, {:update, patch, no_replace}, 15_000)

  def skip_replacement(pid, patch), do: Lixi.Cluster.call(pid, {:skip_replacement, patch}, 15_000)

  def validate(body, resolve \\ true)

  def validate(body, resolve) when is_map(body) do
    with :ok <- validate_settings(body), {:ok, action, data} <- track_action(body) do
      patch = %{
        settings: Map.take(body, ~w(position endTime volume paused filters voice)),
        track: action,
        user_data: data
      }

      if resolve, do: resolve_patch(patch), else: {:ok, patch}
    end
  end

  def validate(_, _), do: {:error, "Expected a JSON object"}

  def resolve_patch(%{track: {kind, value}} = patch) when kind in [:encoded, :identifier] do
    result = if kind == :encoded, do: Lixi.Track.decode(value), else: Lixi.Sources.resolve(value)

    case result do
      {:ok, track} -> {:ok, %{patch | track: {:play, track}}}
      {:error, reason} -> {:error, "Could not resolve track: #{inspect(reason)}"}
    end
  end

  def resolve_patch(patch), do: {:ok, patch}

  defp validate_settings(body) do
    cond do
      Map.has_key?(body, "volume") and
          not (is_integer(body["volume"]) and body["volume"] in 0..1000) ->
        {:error, "volume must be between 0 and 1000"}

      Map.has_key?(body, "paused") and not is_boolean(body["paused"]) ->
        {:error, "paused must be a boolean"}

      Map.has_key?(body, "position") and
          not (is_integer(body["position"]) and body["position"] >= 0 and
                   body["position"] <= 9_007_199_254_740_991) ->
        {:error, "position must be a non-negative integer"}

      Map.has_key?(body, "endTime") and
          not (is_nil(body["endTime"]) or (is_integer(body["endTime"]) and body["endTime"] > 0)) ->
        {:error, "endTime must be positive or null"}

      Map.has_key?(body, "voice") and not voice_valid?(body["voice"]) ->
        {:error, "voice requires token, endpoint, sessionId and channelId"}

      Map.has_key?(body, "filters") ->
        Lixi.Filters.validate(body["filters"])

      true ->
        :ok
    end
  end

  defp voice_valid?(voice) when is_map(voice) do
    Enum.all?(~w(token endpoint sessionId channelId), fn key ->
      is_binary(voice[key]) and byte_size(voice[key]) in 1..4096
    end) and
      Regex.match?(~r/^[0-9]{1,20}$/, voice["channelId"])
  end

  defp voice_valid?(_), do: false

  defp track_action(body) do
    cond do
      Map.has_key?(body, "track") and
          (Map.has_key?(body, "encodedTrack") or Map.has_key?(body, "identifier")) ->
        {:error, "track cannot be combined with deprecated track fields"}

      Map.has_key?(body, "track") ->
        resolve_track(body["track"])

      Map.has_key?(body, "encodedTrack") and Map.has_key?(body, "identifier") ->
        {:error, "encodedTrack and identifier are mutually exclusive"}

      Map.has_key?(body, "encodedTrack") ->
        resolve_track(%{"encoded" => body["encodedTrack"]})

      Map.has_key?(body, "identifier") ->
        resolve_track(%{"identifier" => body["identifier"]})

      true ->
        {:ok, :keep, :keep}
    end
  end

  defp resolve_track(track) when is_map(track) do
    data = Map.get(track, "userData", :keep)

    cond do
      data != :keep and not is_map(data) ->
        {:error, "userData must be an object"}

      Map.has_key?(track, "encoded") and Map.has_key?(track, "identifier") ->
        {:error, "encoded and identifier are mutually exclusive"}

      Map.has_key?(track, "encoded") and is_nil(track["encoded"]) ->
        {:ok, :stop, data}

      Map.has_key?(track, "encoded") ->
        if is_binary(track["encoded"]),
          do: {:ok, {:encoded, track["encoded"]}, data},
          else: {:error, "encoded must be a string or null"}

      Map.has_key?(track, "identifier") ->
        if is_binary(track["identifier"]),
          do: {:ok, {:identifier, track["identifier"]}, data},
          else: {:error, "identifier must be a string"}

      true ->
        {:ok, :keep, data}
    end
  end

  defp resolve_track(_), do: {:error, "track must be an object"}
  @impl true
  def init(opts) do
    key = {:player, Keyword.fetch!(opts, :session), Keyword.fetch!(opts, :guild)}

    case Lixi.Cluster.claim(key) do
      {:ok, _} -> init_owned(opts)
      {:error, :owned} -> {:stop, :already_owned}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_owned(opts) do
    session = Keyword.fetch!(opts, :session)
    guild = Keyword.fetch!(opts, :guild)
    lease = Keyword.get(opts, :worker_lease)

    if lease do
      :ok = Lixi.Admission.transfer(lease, self())
      Process.send_after(self(), :expire_reservation, 15_000)
    end

    Registry.register(Lixi.Registry, {:player, session, guild}, nil)
    Lixi.Cluster.Owners.watch(self(), session)

    Process.send_after(
      self(),
      :player_update,
      Application.fetch_env!(:lixi, :player_update_interval)
    )

    {:ok,
     Lixi.Upgrade.defaults(__MODULE__, %{
       session: session,
       guild: guild,
       user: Keyword.fetch!(opts, :user),
       owner: Keyword.get(opts, :owner, Process.whereis(Lixi.Sessions)),
       owner_epoch: 0,
       owner_monitor: Process.monitor(Keyword.get(opts, :owner, Process.whereis(Lixi.Sessions))),
       track: nil,
       volume: 100,
       paused: false,
       filters: %{},
       voice: %{"token" => nil, "endpoint" => nil, "sessionId" => nil, "channelId" => nil},
       adapter: Application.fetch_env!(:lixi, :voice_module),
       connection: nil,
       connected: false,
       ping: -1,
       key_fingerprint: nil,
       ready: false,
       speaking: false,
       buffering: true,
       position: 0,
       end_time: nil,
       started: false,
       epoch: 0,
       worker_lease: lease,
       worker: nil,
       worker_monitor: nil,
       source_version: nil,
       worker_done: false,
       received: 0,
       limit: 0,
       queue: :queue.new(),
       count: 0,
       timer: nil,
       token: nil,
       retries: []
     })}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, public(state), state}

  def handle_call({:skip_replacement, patch}, from, state) do
    if state.track != nil and patch.track != :keep do
      patch = %{
        patch
        | track: :keep,
          user_data: :keep,
          settings: Map.drop(patch.settings, ~w(paused position endTime))
      }

      handle_call({:update, patch, false}, from, state)
    else
      {:reply, :continue, state}
    end
  end

  def handle_call({:update, patch, no_replace}, _, state) do
    ignored_track = no_replace and state.track != nil and patch.track != :keep
    action = if ignored_track, do: :keep, else: patch.track

    settings =
      cond do
        ignored_track -> Map.drop(patch.settings, ~w(paused position endTime))
        patch.track != :keep -> Map.put_new(patch.settings, "paused", false)
        true -> patch.settings
      end

    state =
      case action do
        :keep ->
          state

        :stop ->
          finish(state, "stopped")

        {:play, track} ->
          state = if state.track, do: finish(state, "replaced"), else: state

          %{
            state
            | track: track,
              position: get_in(track, ["info", "position"]),
              end_time: nil,
              started: false,
              source_version: nil,
              retries: []
          }
      end

    state =
      if not ignored_track and patch.user_data != :keep and state.track,
        do: put_in(state, [:track, "userData"], patch.user_data),
        else: state

    previous = state

    state = %{
      state
      | volume: Map.get(settings, "volume", state.volume),
        paused: Map.get(settings, "paused", state.paused),
        filters:
          if(Map.has_key?(settings, "filters"),
            do: Lixi.Filters.normalize(settings["filters"]),
            else: state.filters
          ),
        end_time: Map.get(settings, "endTime", state.end_time)
    }

    new_track = match?({:play, _}, action)

    rebuild =
      new_track or Map.has_key?(settings, "position") or state.filters != previous.filters or
        state.volume != previous.volume or state.end_time != previous.end_time

    state =
      if Map.has_key?(settings, "voice") and settings["voice"] != state.voice,
        do: connect(state, settings["voice"]),
        else: state

    state =
      cond do
        state.track && rebuild ->
          restart_audio(state, Map.get(settings, "position", state.position))

        state.paused and not previous.paused ->
          state |> quiesce() |> cancel_tick()

        not state.paused and previous.paused ->
          state |> refill() |> schedule(0)

        true ->
          state
      end

    state = sync_playing(state)
    {:reply, {:ok, public(state)}, state}
  end

  defp connect(state, voice) do
    if state.connection do
      connection = state.connection
      ref = Process.monitor(connection)
      state.adapter.close(connection)

      receive do
        {:DOWN, ^ref, :process, ^connection, _} -> :ok
      after
        500 ->
          Process.exit(connection, :kill)

          receive do
            {:DOWN, ^ref, :process, ^connection, _} -> :ok
          after
            500 -> :ok
          end
      end

      Process.demonitor(ref, [:flush])

      if not Process.alive?(connection),
        do: Lixi.Cluster.release({:voice, state.user, state.guild}, connection)
    end

    state = %{
      state
      | voice: voice,
        connection: nil,
        connected: false,
        ready: false,
        speaking: false
    }

    context = Map.put(voice, :previous_key_fingerprint, state.key_fingerprint)

    case state.adapter.start(self(), state.user, state.guild, context) do
      {:ok, connection} ->
        Process.monitor(connection)
        %{state | connection: connection}

      {:error, reason} ->
        emit(state, %{
          op: "event",
          type: "WebSocketClosedEvent",
          guildId: state.guild,
          code: 4017,
          reason: inspect(reason),
          byRemote: false
        })

        state
    end
  end

  defp restart_audio(state, position) do
    state = state |> quiesce() |> stop_worker() |> cancel_tick()
    epoch = state.epoch + 1
    if state.connection, do: state.adapter.fence(state.connection, epoch)

    state = %{
      state
      | epoch: epoch,
        queue: :queue.new(),
        count: 0,
        position: position,
        worker_done: false,
        received: 0,
        limit: 0
    }

    if position >= state.track["info"]["length"] and state.track["info"]["length"] > 0 do
      finish(state, "finished")
    else
      open_worker(state, position)
    end
  end

  defp open_worker(state, position) do
    permit =
      case Map.get(state, :worker_lease) do
        nil -> Lixi.Admission.acquire()
        lease -> {:ok, lease}
      end

    case permit do
      {:ok, lease} ->
        state = Map.put(state, :worker_lease, lease)

        options = [
          lease: lease,
          position: position,
          gain: state.volume / 100,
          filters: state.filters,
          source_version: state.source_version,
          end_time: state.end_time
        ]

        case Worker.start(self(), state.track["info"]["identifier"], state.epoch, options) do
          {:ok, worker} ->
            %{
              state
              | worker: worker,
                worker_monitor: Process.monitor(worker),
                received: 0,
                limit: 0,
                worker_done: false
            }

          {:error, reason} ->
            fail_track(state, reason)
        end

      {:error, reason} ->
        fail_track(state, reason)
    end
  end

  @impl true
  def handle_info(:expire_reservation, %{track: nil} = state) do
    Lixi.Admission.release(Map.get(state, :worker_lease))
    {:noreply, Map.put(state, :worker_lease, nil)}
  end

  def handle_info(:expire_reservation, state), do: {:noreply, state}

  def handle_info(
        {:audio, worker, epoch, {:ready, metadata}},
        %{worker: worker, epoch: epoch} = state
      ) do
    state = %{state | source_version: metadata[:source_version]}
    {:noreply, state |> refill() |> schedule(0)}
  end

  def handle_info(
        {:audio, worker, epoch, {:frame, frame}},
        %{worker: worker, epoch: epoch} = state
      ) do
    if state.count >= 25 or state.received >= state.limit do
      {:noreply, fail_track(state, :output_budget_exceeded)}
    else
      {:noreply,
       %{
         state
         | queue: :queue.in(frame, state.queue),
           count: state.count + 1,
           received: state.received + 1
       }}
    end
  end

  def handle_info({:audio, worker, epoch, :end}, %{worker: worker, epoch: epoch} = state) do
    state = stop_worker(state)
    {:noreply, %{state | worker_done: true} |> schedule(0)}
  end

  def handle_info(
        {:audio, worker, epoch, {:error, {:worker_exit, _} = reason}},
        %{worker: worker, epoch: epoch} = state
      ),
      do: {:noreply, recover(state, reason)}

  def handle_info(
        {:audio, worker, epoch, {:error, reason}},
        %{worker: worker, epoch: epoch} = state
      ),
      do: {:noreply, fail_track(state, reason)}

  def handle_info({:audio, _, _, _}, state), do: {:noreply, state}

  def handle_info({:voice, pid, :ready}, %{connection: pid} = state) do
    state.adapter.fence(pid, state.epoch)
    {:noreply, %{state | connected: true, ready: true, speaking: false} |> schedule(0)}
  end

  def handle_info({:voice, pid, :buffering}, %{connection: pid} = state),
    do: {:noreply, %{state | ready: false, speaking: false, buffering: true}}

  def handle_info({:voice, pid, :disconnected}, %{connection: pid} = state),
    do: {:noreply, %{state | connected: false, ready: false}}

  def handle_info({:voice, pid, {:ping, ping}}, %{connection: pid} = state),
    do: {:noreply, %{state | ping: ping}}

  def handle_info({:voice, pid, {:key_fingerprint, fingerprint}}, %{connection: pid} = state),
    do: {:noreply, %{state | key_fingerprint: fingerprint}}

  def handle_info({:voice, pid, {:closed, code, reason, remote}}, %{connection: pid} = state) do
    emit(state, %{
      op: "event",
      type: "WebSocketClosedEvent",
      guildId: state.guild,
      code: code,
      reason: reason,
      byRemote: remote
    })

    {:noreply, %{state | connected: false, ready: false}}
  end

  def handle_info({:voice, _, _}, state), do: {:noreply, state}

  def handle_info({:tick, epoch, token, due}, %{epoch: epoch, token: token} = state),
    do: {:noreply, tick(state, due)}

  def handle_info({:tick, _, _, _}, state), do: {:noreply, state}

  def handle_info(:player_update, state) do
    emit(state, %{op: "playerUpdate", guildId: state.guild, state: public_state(state)})

    Process.send_after(
      self(),
      :player_update,
      Application.fetch_env!(:lixi, :player_update_interval)
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{worker_monitor: ref} = state),
    do: {:noreply, recover(state, reason)}

  def handle_info({:DOWN, _, :process, pid, _}, %{connection: pid} = state),
    do: {:noreply, %{state | connection: nil, connected: false, ready: false}}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    Lixi.Cluster.Owners.refresh()
    {:noreply, %{state | owner_monitor: nil}}
  end

  def handle_info({:session_authority, owner, epoch}, state) when epoch >= state.owner_epoch do
    if owner != state.owner or state.owner_monitor == nil do
      if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
      monitor = if node(owner) == node() or node(owner) in Node.list(), do: Process.monitor(owner)
      {:noreply, %{state | owner: owner, owner_monitor: monitor, owner_epoch: epoch}}
    else
      {:noreply, %{state | owner_epoch: epoch}}
    end
  end

  def handle_info({:session_authority, _, _}, state), do: {:noreply, state}

  def handle_info({:session_missing, revision}, state) when revision >= state.owner_epoch,
    do: {:stop, :normal, state}

  def handle_info({:session_missing, _}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  defp tick(%{track: nil} = state, _), do: cancel_tick(state)
  defp tick(%{paused: true} = state, _), do: cancel_tick(state)
  defp tick(%{worker_done: true, count: 0} = state, _), do: finish(state, "finished")
  defp tick(%{ready: false} = state, _), do: schedule(state, 100_000)

  defp tick(%{count: 0} = state, _) do
    if not state.buffering, do: Lixi.Metrics.record(:underruns)
    state |> quiesce() |> Map.put(:buffering, true) |> schedule(100_000)
  end

  defp tick(%{buffering: true, worker_done: false, count: count} = state, _) when count < 10,
    do: schedule(state, 20_000)

  defp tick(state, due) do
    state = ensure_speaking(state)
    {{:value, frame}, queue} = :queue.out(state.queue)
    now = System.monotonic_time(:microsecond)
    if now - due >= 20_000, do: Lixi.Metrics.record(:late, div(now - due, 20_000))
    due = if now - due >= 20_000, do: now, else: due

    result =
      if state.speaking,
        do: state.adapter.send_frame(state.connection, frame, state.epoch, due),
        else: {:error, :not_ready}

    case result do
      :ok ->
        Lixi.Metrics.record(:sent)

        state =
          if state.started do
            state
          else
            Registry.register(Lixi.Registry, {:playing, state.session, state.guild}, nil)
            Lixi.Metrics.playing(self(), true)

            emit(state, %{
              op: "event",
              type: "TrackStartEvent",
              guildId: state.guild,
              track: state.track
            })

            %{state | started: true}
          end

        %{
          state
          | position: frame.position,
            queue: queue,
            count: state.count - 1,
            buffering: false
        }
        |> refill()
        |> schedule_at(due + 20_000)

      {:error, :expired} ->
        schedule(state, 20_000)

      {:error, :not_ready} ->
        schedule(state, 100_000)

      {:error, _} ->
        Lixi.Metrics.record(:send_errors)
        %{state | ready: false, connected: false}
    end
  end

  defp refill(%{worker: nil} = state), do: state
  defp refill(%{paused: true} = state), do: state

  defp refill(state) do
    reserved = state.limit - state.received
    available = 15 - state.count - reserved

    if available >= 5 do
      limit = state.limit + min(available, 15)
      Worker.grant(state.worker, limit)
      %{state | limit: limit}
    else
      state
    end
  end

  defp recover(%{track: nil} = state, _), do: stop_worker(state)

  defp recover(state, reason) do
    state = stop_worker(state)
    now = System.monotonic_time(:millisecond)
    retries = Enum.filter(state.retries, &(now - &1 < 60_000))

    if length(retries) >= 3 do
      fail_track(state, reason)
    else
      position =
        case :queue.peek_r(state.queue) do
          {:value, frame} -> frame.position
          :empty -> state.position
        end

      open_worker(%{state | retries: [now | retries]}, position) |> schedule(0)
    end
  end

  defp stop_worker(state) do
    Worker.stop(state.worker)
    if state.worker_monitor, do: Process.demonitor(state.worker_monitor, [:flush])
    %{state | worker: nil, worker_monitor: nil}
  end

  defp finish(%{track: nil} = state, _), do: state

  defp finish(state, reason) do
    state = quiesce(state)

    emit(state, %{
      op: "event",
      type: "TrackEndEvent",
      guildId: state.guild,
      track: state.track,
      reason: reason
    })

    Lixi.Metrics.playing(self(), false)
    Registry.unregister(Lixi.Registry, {:playing, state.session, state.guild})
    state = stop_worker(state) |> cancel_tick()

    state =
      if reason == "replaced" do
        state
      else
        Lixi.Admission.release(Map.get(state, :worker_lease))
        Map.put(state, :worker_lease, nil)
      end

    %{
      state
      | track: nil,
        queue: :queue.new(),
        count: 0,
        worker_done: false,
        started: false,
        source_version: nil
    }
  end

  defp fail_track(state, reason) do
    if state.track,
      do:
        emit(state, %{
          op: "event",
          type: "TrackExceptionEvent",
          guildId: state.guild,
          track: state.track,
          exception: %{
            message: "Audio playback failed",
            severity: "fault",
            cause: inspect(reason),
            causeStackTrace: ""
          }
        })

    finish(state, "loadFailed")
  end

  defp quiesce(%{connection: pid, ready: true, speaking: true, adapter: adapter} = state)
       when is_pid(pid) do
    adapter.quiesce(pid)
    %{state | speaking: false}
  end

  defp quiesce(state), do: %{state | speaking: false}

  defp ensure_speaking(%{speaking: true} = state), do: state

  defp ensure_speaking(state) do
    case state.adapter.resume(state.connection) do
      :ok -> %{state | speaking: true}
      _ -> state
    end
  end

  defp sync_playing(state) do
    key = {:playing, state.session, state.guild}

    Lixi.Metrics.playing(self(), state.track != nil and state.started and not state.paused)

    if state.track != nil and state.started and not state.paused,
      do: Registry.register(Lixi.Registry, key, nil),
      else: Registry.unregister(Lixi.Registry, key)

    state
  end

  defp cancel_tick(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil, token: nil}
  end

  defp schedule(state, delay), do: schedule_at(state, System.monotonic_time(:microsecond) + delay)

  defp schedule_at(state, due) do
    state = cancel_tick(state)
    token = make_ref()
    delay = max(0, div(due - System.monotonic_time(:microsecond) + 999, 1000))
    timer = Process.send_after(self(), {:tick, state.epoch, token, due}, delay)
    %{state | timer: timer, token: token}
  end

  defp emit(state, event), do: Lixi.Sessions.emit_to(state.owner, state.session, event)

  defp public(state),
    do: %{
      "guildId" => state.guild,
      "track" => state.track,
      "volume" => state.volume,
      "paused" => state.paused,
      "state" => public_state(state),
      "voice" => state.voice,
      "filters" => state.filters
    }

  defp public_state(state),
    do: %{
      "time" => System.system_time(:millisecond),
      "position" => state.position,
      "connected" => state.connected,
      "ping" => if(state.connected, do: state.ping, else: -1)
    }

  @impl true
  def terminate(_, state) do
    Worker.stop(state.worker)
    Lixi.Admission.release(Map.get(state, :worker_lease))
    if state.connection, do: state.adapter.close(state.connection)
  end

  @impl true
  def code_change(_, state, _) do
    owner = Map.get(state, :owner, Process.whereis(Lixi.Sessions))

    state = Map.put_new(state, :owner, owner)

    state =
      if Map.has_key?(state, :owner_monitor),
        do: state,
        else: Map.put(state, :owner_monitor, Process.monitor(owner))

    {:ok, state}
  end
end
