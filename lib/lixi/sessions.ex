defmodule Lixi.Sessions do
  @moduledoc "Owns client session lifetime; player work never runs in this process."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def connect(user, socket, previous \\ nil),
    do: connect_routed(user, socket, previous)

  def settings(id, patch), do: routed(id, {:settings, id, patch})
  def user(id), do: routed(id, {:user, id})

  def emit(id, event) do
    with {:ok, owner} <- Lixi.Cluster.lookup({:session, id}),
         do: GenServer.cast(owner, {:emit, id, event})
  end

  def emit_to(owner, id, event), do: Lixi.Events.emit(owner, id, event)

  def player(id, guild, create \\ false),
    do: routed(id, {:player, id, guild, create})

  def players(id), do: routed(id, {:players, id})
  def destroy(id, guild), do: routed(id, {:destroy, id, guild})
  def move(id, target), do: routed(id, {:move, id, target})
  def local_metrics, do: GenServer.call(__MODULE__, :metrics)

  defp routed(id, message) do
    with {:ok, owner} <- Lixi.Cluster.lookup({:session, id}) do
      result = Lixi.Cluster.call(owner, {:owned_request, id, message}, 15_000)

      if result in [{:error, :not_found}, {:error, :owner_changed}, {:error, :moving}] do
        case Lixi.Cluster.lookup({:session, id}) do
          {:ok, next} when next != owner ->
            Lixi.Cluster.call(next, {:owned_request, id, message}, 15_000)

          _ ->
            result
        end
      else
        result
      end
    end
  end

  defp connect_routed(user, socket, previous) do
    case Lixi.Cluster.lookup({:session, previous}) do
      {:ok, owner} ->
        case Lixi.Cluster.call(owner, {:connect, user, socket, previous}, 15_000) do
          {:error, :draining} -> connect_new(user, socket)
          result -> result
        end

      {:error, :not_found} ->
        connect_new(user, socket)

      error ->
        error
    end
  end

  defp connect_new(user, socket) do
    with {:ok, candidates} <- Lixi.Cluster.candidates({user, make_ref()}) do
      Enum.reduce_while(candidates, {:error, :capacity}, fn instance, _ ->
        case Lixi.Cluster.call({__MODULE__, instance}, {:connect, user, socket, nil}, 15_000) do
          {:ok, _, _, _} = result -> {:halt, result}
          error -> {:cont, error}
        end
      end)
    end
  end

  @impl true
  def init(_),
    do:
      {:ok,
       Lixi.Upgrade.defaults(__MODULE__, %{sessions: %{}, refs: %{}, releases: MapSet.new()})}

  @impl true
  def handle_call({:owned_request, id, message}, from, state) do
    case state.sessions[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status in [:staged, :transferring] ->
        {:reply, {:error, :moving}, state}

      _ ->
        handle_call(message, from, state)
    end
  end

  def handle_call({:move, _id, target}, _, state) when target == node(), do: {:reply, :ok, state}

  def handle_call({:move, id, target}, _, state) do
    original = state.sessions[id]
    reference = make_ref()

    remaining =
      if original.timer,
        do: Process.read_timer(original.timer) || 0,
        else: original.timeout * 1000

    export = original |> Map.put(:expires_in, remaining) |> Map.put(:id, id)

    with {:ok, entry} <- Lixi.Cluster.entry({:session, id}),
         true <- entry.owner == self(),
         {:ok, receiver} <-
           Lixi.Cluster.call(
             {__MODULE__, target},
             {:prepare_import, id, export, self(), entry.token, reference}
           ) do
      if original.timer, do: Process.cancel_timer(original.timer)
      if original.monitor, do: Process.demonitor(original.monitor, [:flush])

      session =
        export
        |> Map.put(:status, :transferring)
        |> Map.put(:move_ref, reference)
        |> Map.put(:prepared_at, System.monotonic_time(:millisecond))
        |> Map.put(:monitor, nil)
        |> Map.put(:timer, nil)
        |> Map.put(:generation, make_ref())

      state =
        %{state | refs: Map.delete(state.refs, original.monitor)}
        |> put_in([:sessions, id], session)

      command = {:begin_move, {:session, id}, self(), receiver, entry.token, reference}

      result =
        case Lixi.Cluster.Coordinator.command(command) do
          {:ok, _} -> Lixi.Cluster.call(receiver, {:activate_import, id})
          _ -> {:error, :transfer_pending}
        end

      if result == :ok do
        {:reply, :ok, drop_replica(state, id)}
      else
        Process.send_after(self(), {:reconcile_move, id}, 500)
        {:reply, {:error, :transfer_pending}, state}
      end
    else
      _ -> {:reply, {:error, :transfer_unavailable}, state}
    end
  end

  def handle_call({:prepare_import, id, session, source, expected, reference}, _, state) do
    cond do
      not Lixi.Lifecycle.accepting?() ->
        {:reply, {:error, :draining}, state}

      Map.has_key?(state.sessions, id) ->
        {:reply, {:error, :import_conflict}, state}

      map_size(state.sessions) >= Application.fetch_env!(:lixi, :max_sessions) ->
        {:reply, {:error, :capacity}, state}

      true ->
        session =
          session
          |> Map.put(:id, id)
          |> Map.put(:status, :staged)
          |> Map.put(:source, source)
          |> Map.put(:expected_epoch, expected)
          |> Map.put(:move_ref, reference)
          |> Map.put(:player_monitors, %{})
          |> Map.put(:monitor, nil)
          |> Map.put(:timer, nil)
          |> Map.put(:prepared_at, System.monotonic_time(:millisecond))

        Process.send_after(self(), {:reconcile_move, id}, 500)
        {:reply, {:ok, self()}, put_in(state, [:sessions, id], session)}
    end
  end

  def handle_call({:activate_import, id}, _, state) do
    case {state.sessions[id], Lixi.Cluster.entry({:session, id})} do
      {%{status: :active}, {:ok, %{owner: owner}}} when owner == self() ->
        {:reply, :ok, state}

      {%{status: :staged} = session, {:ok, %{owner: owner, token: epoch} = entry}}
      when owner == self() ->
        reference = session.move_ref

        if (entry[:move_ref] == reference or entry[:completed_move] == reference) and
             finish_import(id, reference) == :ok do
          session = activate_record(session, epoch)
          {:reply, :ok, put_in(state, [:sessions, id], session) |> monitor_socket(id)}
        else
          Process.send_after(self(), {:reconcile_move, id}, 500)
          {:reply, {:error, :transfer_pending}, state}
        end

      _ ->
        {:reply, {:error, :owner_changed}, state}
    end
  end

  def handle_call(:metrics, _, state), do: {:reply, %{sessions: map_size(state.sessions)}, state}

  def handle_call({:connect, user, socket, previous}, _from, state) do
    case Map.get(state.sessions, previous) do
      %{status: status} when status in [:staged, :transferring] ->
        {:reply, {:error, :moving}, state}

      %{user: ^user, socket: nil, resuming: true} = session ->
        if session.timer, do: Process.cancel_timer(session.timer)
        ref = Process.monitor(socket)

        session = %{
          session
          | socket: socket,
            monitor: ref,
            timer: nil,
            generation: make_ref(),
            events: :queue.new(),
            event_count: 0
        }

        events = :queue.to_list(state.sessions[previous].events)
        {:reply, {:ok, previous, true, events}, put_session(state, previous, session, ref)}

      _ ->
        cond do
          not Lixi.Lifecycle.accepting?() ->
            {:reply, {:error, :draining}, state}

          map_size(state.sessions) >= Application.fetch_env!(:lixi, :max_sessions) ->
            {:reply, {:error, :capacity}, state}

          true ->
            id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
            ref = Process.monitor(socket)

            session = %{
              user: user,
              socket: socket,
              monitor: ref,
              resuming: false,
              timeout: 60,
              timer: nil,
              generation: make_ref(),
              events: :queue.new(),
              event_count: 0,
              players: %{},
              player_monitors: %{}
            }

            state = put_session(state, id, session, ref)

            case Lixi.Cluster.claim({:session, id}) do
              {:ok, _} -> {:reply, {:ok, id, false, []}, state}
              {:error, _} = error -> {:reply, error, state}
            end
        end
    end
  end

  def handle_call({:settings, id, patch}, _from, state) do
    case state.sessions do
      %{^id => session} ->
        session = %{
          session
          | resuming: Map.get(patch, "resuming", session.resuming),
            timeout: Map.get(patch, "timeout", session.timeout)
        }

        session =
          if session.socket == nil do
            if session.timer, do: Process.cancel_timer(session.timer)
            generation = make_ref()
            delay = if session.resuming, do: session.timeout * 1000, else: 0
            timer = Process.send_after(self(), {:expire, id, generation}, delay)
            %{session | generation: generation, timer: timer}
          else
            session
          end

        {:reply, {:ok, %{resuming: session.resuming, timeout: session.timeout}},
         put_in(state, [:sessions, id], session)}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:user, id}, _from, state) do
    {:reply,
     case state.sessions[id] do
       nil -> {:error, :not_found}
       s -> {:ok, s.user}
     end, state}
  end

  def handle_call({:players, id}, _from, state) do
    {:reply,
     case state.sessions[id] do
       nil -> {:error, :not_found}
       s -> {:ok, Map.values(s.players)}
     end, state}
  end

  def handle_call({:player, id, guild, create}, _from, state) do
    with %{players: players} = session <- state.sessions[id] do
      case players[guild] do
        nil when create ->
          case Lixi.Cluster.start_player(id, session.user, guild, self()) do
            {:ok, pid} ->
              session = monitor_player(session, guild, pid)
              {:reply, {:ok, pid}, put_in(state, [:sessions, id], session)}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        nil ->
          {:reply, {:error, :player_not_found}, state}

        pid ->
          {:reply, {:ok, pid}, state}
      end
    else
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:destroy, id, guild}, _from, state) do
    case state.sessions[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        result =
          if pid = session.players[guild], do: Lixi.Cluster.terminate_player(pid), else: :ok

        if result == :ok do
          session = forget_player(session, guild)
          {:reply, :ok, put_in(state, [:sessions, id], session)}
        else
          {:reply, {:error, :unavailable}, state}
        end
    end
  end

  @impl true
  def handle_cast({:emit, id, event}, state) do
    case state.sessions[id] do
      nil ->
        {:noreply, state}

      %{socket: socket} when is_pid(socket) ->
        case Lixi.Cluster.deliver_socket(socket, event) do
          :ok ->
            {:noreply, state}

          _ ->
            if state.sessions[id].resuming do
              s = state.sessions[id]
              if s.monitor, do: Process.demonitor(s.monitor, [:flush])
              timer = Process.send_after(self(), {:expire, id, s.generation}, s.timeout * 1000)
              state = %{state | refs: Map.delete(state.refs, s.monitor)}

              state =
                put_in(state, [:sessions, id], %{s | socket: nil, monitor: nil, timer: timer})

              handle_cast({:emit, id, event}, state)
            else
              {:noreply, remove_session(state, id)}
            end
        end

      %{resuming: true} = s ->
        if (Map.get(event, :op) || Map.get(event, "op")) in ["playerUpdate", "stats"] do
          {:noreply, state}
        else
          if s.event_count < Application.fetch_env!(:lixi, :max_event_buffer) do
            {:noreply,
             put_in(state, [:sessions, id], %{
               s
               | events: :queue.in(event, s.events),
                 event_count: s.event_count + 1
             })}
          else
            {:noreply, remove_session(state, id)}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:reconcile_move, id}, state) do
    case state.sessions[id] do
      %{status: :transferring} = session ->
        case Lixi.Cluster.entry({:session, id}) do
          {:ok, %{owner: owner} = entry} when owner == self() ->
            session = activate_record(session, entry.token)
            {:noreply, put_in(state, [:sessions, id], session) |> monitor_socket(id)}

          {:ok, %{owner: target}} ->
            case Lixi.Cluster.call(target, {:activate_import, id}) do
              :ok ->
                {:noreply, drop_replica(state, id)}

              _ ->
                Process.send_after(self(), {:reconcile_move, id}, 500)
                {:noreply, state}
            end

          {:error, :not_found} ->
            {:noreply, drop_replica(state, id)}

          _ ->
            Process.send_after(self(), {:reconcile_move, id}, 500)
            {:noreply, state}
        end

      %{status: :staged} = staged ->
        case Lixi.Cluster.entry({:session, id}) do
          {:ok, %{owner: owner}} when owner == self() ->
            {:reply, _, state} = handle_call({:activate_import, id}, nil, state)
            {:noreply, state}

          {:ok, %{owner: source, token: expected}}
          when source == staged.source and expected == staged.expected_epoch ->
            elapsed = System.monotonic_time(:millisecond) - staged.prepared_at

            result =
              if elapsed >= 5_000 do
                Lixi.Cluster.Coordinator.command(
                  {:abort_move, {:session, id}, staged.source, self(), staged.expected_epoch,
                   staged.move_ref}
                )
              else
                {:error, :waiting}
              end

            if result == :ok do
              {:noreply, drop_replica(state, id)}
            else
              Process.send_after(self(), {:reconcile_move, id}, 500)
              {:noreply, state}
            end

          {:ok, _} ->
            {:noreply, drop_replica(state, id)}

          {:error, :not_found} ->
            {:noreply, drop_replica(state, id)}

          _ ->
            Process.send_after(self(), {:reconcile_move, id}, 500)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:deliver_event, event_id, bus, id, event}, state) do
    case state.sessions[id] do
      nil ->
        case Lixi.Cluster.lookup({:session, id}) do
          {:ok, owner} when owner != self() -> send(bus, {:event_redirect, event_id, owner})
          {:error, :not_found} -> send(bus, {:event_ack, event_id})
          _ -> :ok
        end

        {:noreply, state}

      %{status: status} when status in [:staged, :transferring] ->
        case Lixi.Cluster.lookup({:session, id}) do
          {:ok, owner} when owner != self() -> send(bus, {:event_redirect, event_id, owner})
          _ -> :ok
        end

        {:noreply, state}

      session ->
        seen = Map.get(session, :seen_events, [])

        if event_id in seen do
          send(bus, {:event_ack, event_id})
          {:noreply, state}
        else
          {:noreply, state} = handle_cast({:emit, id, event}, state)

          state =
            if state.sessions[id],
              do: put_in(state, [:sessions, id, :seen_events], Enum.take([event_id | seen], 512)),
              else: state

          send(bus, {:event_ack, event_id})
          {:noreply, state}
        end
    end
  end

  def handle_info({:event_overflow, id}, state), do: {:noreply, remove_session(state, id)}

  def handle_info(:retry_releases, state) do
    pending =
      Enum.reduce(state.releases, MapSet.new(), fn id, pending ->
        if Lixi.Cluster.release({:session, id}) == :ok, do: pending, else: MapSet.put(pending, id)
      end)

    if MapSet.size(pending) > 0, do: Process.send_after(self(), :retry_releases, 1_000)
    {:noreply, %{state | releases: pending}}
  end

  def handle_info({:nodeup, instance}, state) do
    sessions =
      Map.new(state.sessions, fn {id, session} ->
        session =
          Enum.reduce(session.players, session, fn {guild, pid}, session ->
            if node(pid) == instance and
                 not Map.has_key?(Map.get(session, :player_monitors, %{}), guild),
               do: monitor_player(session, guild, pid),
               else: session
          end)

        {id, session}
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        if reason == :noconnection, do: Node.monitor(node(pid), true)

        sessions =
          Map.new(state.sessions, fn {id, session} ->
            case Enum.find(Map.get(session, :player_monitors, %{}), fn {_, r} -> r == ref end) do
              {guild, _} when reason == :noconnection ->
                {id, Map.update!(session, :player_monitors, &Map.delete(&1, guild))}

              {guild, _} ->
                {id, forget_player(session, guild)}

              nil ->
                {id, session}
            end
          end)

        {:noreply, %{state | sessions: sessions}}

      {id, refs} ->
        state = %{state | refs: refs}

        case state.sessions[id] do
          %{resuming: true} = s ->
            generation = make_ref()
            timer = Process.send_after(self(), {:expire, id, generation}, s.timeout * 1_000)

            {:noreply,
             put_in(state, [:sessions, id], %{
               s
               | socket: nil,
                 monitor: nil,
                 timer: timer,
                 generation: generation
             })}

          _ ->
            {:noreply, remove_session(state, id)}
        end
    end
  end

  def handle_info({:expire, id, generation}, state) do
    case state.sessions[id] do
      %{generation: ^generation, socket: nil} -> {:noreply, remove_session(state, id)}
      _ -> {:noreply, state}
    end
  end

  defp put_session(state, id, session, ref),
    do: %{
      state
      | sessions: Map.put(state.sessions, id, session),
        refs: Map.put(state.refs, ref, id)
    }

  defp remove_session(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _} ->
        state

      {session, sessions} ->
        Enum.each(session.players, fn {_, pid} ->
          Lixi.Cluster.terminate_player(pid)
        end)

        if session.monitor, do: Process.demonitor(session.monitor, [:flush])
        if session.timer, do: Process.cancel_timer(session.timer)
        clear_player_monitors(session)
        state = %{state | sessions: sessions, refs: Map.delete(state.refs, session.monitor)}

        if Lixi.Cluster.release({:session, id}) == :ok do
          state
        else
          if MapSet.size(state.releases) == 0,
            do: Process.send_after(self(), :retry_releases, 1_000)

          %{state | releases: MapSet.put(state.releases, id)}
        end
    end
  end

  @impl true
  def code_change(_, state, _), do: {:ok, Map.put_new(state, :releases, MapSet.new())}

  defp activate_record(session, epoch) do
    generation = make_ref()

    timer =
      if session.socket == nil do
        elapsed =
          max(
            0,
            System.monotonic_time(:millisecond) -
              Map.get(session, :prepared_at, System.monotonic_time(:millisecond))
          )

        Process.send_after(
          self(),
          {:expire, session.id, generation},
          max(0, Map.get(session, :expires_in, session.timeout * 1000) - elapsed)
        )
      end

    for {_guild, pid} <- session.players, do: send(pid, {:session_authority, self(), epoch})
    if session.socket, do: send(session.socket, {:session_owner_changed, session.id, self()})

    session
    |> clear_player_monitors()
    |> monitor_players()
    |> Map.put(:status, :active)
    |> Map.put(:generation, generation)
    |> Map.put(:timer, timer)
    |> Map.put(:monitor, nil)
  end

  defp monitor_socket(state, id) do
    session = state.sessions[id]

    if session.socket do
      ref = Process.monitor(session.socket)
      put_session(state, id, %{session | monitor: ref}, ref)
    else
      state
    end
  end

  defp drop_replica(state, id) do
    session = state.sessions[id]
    if session.monitor, do: Process.demonitor(session.monitor, [:flush])
    if session.timer, do: Process.cancel_timer(session.timer)
    clear_player_monitors(session)

    %{
      state
      | sessions: Map.delete(state.sessions, id),
        refs: Map.delete(state.refs, session.monitor)
    }
  end

  defp finish_import(id, reference) do
    case Lixi.Cluster.Coordinator.command({:finish_move, {:session, id}, self(), reference}) do
      :ok ->
        :ok

      _ ->
        case Lixi.Cluster.entry({:session, id}) do
          {:ok, %{owner: owner, completed_move: ^reference}} when owner == self() -> :ok
          _ -> {:error, :transfer_pending}
        end
    end
  end

  defp monitor_player(session, guild, pid) do
    monitors = Map.get(session, :player_monitors, %{})
    if previous = monitors[guild], do: Process.demonitor(previous, [:flush])
    monitors = Map.put(monitors, guild, Process.monitor(pid))

    session
    |> Map.update!(:players, &Map.put(&1, guild, pid))
    |> Map.put(:player_monitors, monitors)
  end

  defp monitor_players(session),
    do:
      Enum.reduce(session.players, session, fn {guild, pid}, s ->
        monitor_player(s, guild, pid)
      end)

  defp clear_player_monitors(session) do
    for {_, ref} <- Map.get(session, :player_monitors, %{}),
        do: Process.demonitor(ref, [:flush])

    Map.put(session, :player_monitors, %{})
  end

  defp forget_player(session, guild) do
    monitors = Map.get(session, :player_monitors, %{})
    if ref = monitors[guild], do: Process.demonitor(ref, [:flush])

    session
    |> Map.put(:players, Map.delete(session.players, guild))
    |> Map.put(:player_monitors, Map.delete(monitors, guild))
  end
end
