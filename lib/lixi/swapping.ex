defmodule Lixi.Swapping do
  @moduledoc "Two bounded native roles, with public track changes committed by the Voice clock."
  alias Lixi.Audio.Worker

  @defaults %{
    "soundCheck" => true,
    "autoMix" => true,
    "targetLufs" => -16.0,
    "peakCeilingDb" => -1.0,
    "maxBoostDb" => 12.0,
    "fadeMs" => 2500,
    "maxTempoChange" => 0.06
  }

  def request(
        version,
        %{method: method, path: ["sessions", session, "players", guild | action]} = req
      )
      when method in ["GET", "PUT", "POST", "DELETE"] do
    with {:ok, player} <- Lixi.Sessions.player(session, guild, method == "PUT") do
      result =
        case {method, action} do
          {"GET", []} ->
            Lixi.Cluster.call(player, {:swapping, :status})

          {"PUT", []} ->
            Lixi.Cluster.call(player, {:swapping, {:configure, version, req.body}})

          {"POST", ["next"]} ->
            with {:ok, patch} <- Lixi.Player.validate(req.body),
                 {:play, track} <- patch.track,
                 true <- patch.settings == %{} do
              Lixi.Cluster.call(player, {:swapping, {:prepare, track}})
            else
              _ -> {:error, :invalid_next_track}
            end

          {"DELETE", ["next"]} ->
            Lixi.Cluster.call(player, {:swapping, :cancel})

          {"POST", ["skip"]} ->
            Lixi.Cluster.call(player, {:swapping, :skip})

          _ ->
            {:error, :not_found}
        end

      case result do
        {:ok, body} -> {:ok, if(method == "POST", do: 202, else: 200), body}
        {:error, reason} -> {:ok, 409, %{error: inspect(reason)}}
      end
    else
      {:error, reason} -> {:ok, 404, %{error: inspect(reason)}}
    end
  end

  def request(_, _), do: {:ok, 404, %{error: "Plugin route not found"}}

  def settings(body, previous \\ @defaults)

  def settings(body, previous) when is_map(body) do
    values = Map.merge(previous, Map.drop(body, ["enabled"]))

    if Map.keys(values) |> Enum.sort() == Enum.sort(Map.keys(@defaults)) and
         Enum.all?(~w(soundCheck autoMix), &is_boolean(values[&1])) and
         number?(values["targetLufs"], -30, -8) and number?(values["peakCeilingDb"], -6, 0) and
         number?(values["maxBoostDb"], 0, 18) and is_integer(values["fadeMs"]) and
         values["fadeMs"] in 0..12_000 and number?(values["maxTempoChange"], 0, 0.12),
       do: {:ok, values},
       else: {:error, :invalid_settings}
  end

  def settings(_, _), do: {:error, :invalid_settings}
  defp number?(value, low, high), do: is_number(value) and value >= low and value <= high

  def configure(state, version, body) when is_map(body) do
    current = Map.get(state, :swapping)
    enabled = Map.get(body, "enabled", true)

    cond do
      not is_boolean(enabled) ->
        {{:error, :invalid_settings}, state}

      not enabled and state.worker != nil ->
        {{:error, :stop_player_before_disabling}, state}

      not enabled ->
        state = close(state)
        {{:ok, %{enabled: false}}, Map.put(state, :swapping, nil)}

      current == nil and state.worker != nil ->
        {{:error, :enable_before_playing}, state}

      true ->
        with {:ok, settings} <- settings(body, if(current, do: current.settings, else: @defaults)),
             {:ok, swapping} <- configured(current, version, settings) do
          if state.worker, do: Worker.settings(state.worker, settings)
          state = Map.put(state, :swapping, swapping)
          {{:ok, status(state)}, state}
        else
          {:error, _} = error -> {error, state}
        end
    end
  end

  def configure(state, _, _), do: {{:error, :invalid_settings}, state}

  defp configured(nil, version, settings) do
    with {:ok, lease, _} <- Lixi.Plugins.Manager.checkout("swapping", version) do
      {:ok,
       %{
         settings: settings,
         plugin_lease: lease,
         version: version,
         prepare_lease: nil,
         preparer: nil,
         preparer_monitor: nil,
         starting: nil,
         next: nil,
         current: nil,
         jobs: %{},
         sent: 0,
         applied: settings
       }}
    end
  end

  defp configured(current, _, settings), do: {:ok, %{current | settings: settings}}

  def status(state) do
    case Map.get(state, :swapping) do
      nil ->
        %{enabled: false}

      s ->
        %{
          enabled: true,
          epoch: state.epoch,
          version: s.version,
          settings: s.settings,
          applied: s.applied,
          current: s.current,
          next: s.next,
          jobs:
            Enum.map(s.jobs, fn {tag, job} ->
              %{
                tag: tag,
                phase: job.phase,
                track: job.track,
                analysis: job.analysis,
                plan: Map.get(job, :plan)
              }
            end)
        }
    end
  end

  def reserve(%{swapping: s} = state) when s != nil do
    if s.prepare_lease do
      {:ok, state}
    else
      with {:ok, playback, prepare} <- Lixi.Admission.reserve_swapping(state.worker_lease) do
        {:ok, %{state | worker_lease: playback, swapping: %{s | prepare_lease: prepare}}}
      end
    end
  end

  def reserve(state), do: {:ok, state}

  def open(state) do
    case Map.get(state, :swapping) do
      nil ->
        {state, []}

      s ->
        tag = s.current || tag()
        job = Map.get(s.jobs, tag, job(state.track, :playing))
        s = %{s | current: tag, jobs: %{tag => job}, sent: 0, next: nil}
        {%{state | swapping: s}, [swapping: s.settings, tag: tag, report: job.analysis]}
    end
  end

  def prepare(%{swapping: s, worker: worker} = state, track) when s != nil and worker != nil do
    if s.next == nil and s.starting == nil and map_size(s.jobs) <= 1 do
      tag = tag()
      ticket = tag()
      owner = self()
      previous = s.preparer

      options = [
        lease: s.prepare_lease,
        purpose: :prepare,
        swapping: s.settings,
        mode: "prepare",
        tag: tag
      ]

      task =
        Task.Supervisor.async_nolink(Lixi.TaskSupervisor, fn ->
          Worker.stop(previous)
          Worker.start(owner, track["info"]["identifier"], ticket, options)
        end)

      if s.preparer_monitor, do: Process.demonitor(s.preparer_monitor, [:flush])
      starting = %{ref: task.ref, tag: tag, ticket: ticket, cancelled: false, early: nil}

      s = %{
        s
        | next: tag,
          jobs: Map.put(s.jobs, tag, job(track, :analysing)),
          preparer: nil,
          preparer_monitor: nil,
          starting: starting
      }

      state = %{state | swapping: s}
      {{:ok, status(state)}, state}
    else
      {{:error, :next_occupied}, state}
    end
  end

  def prepare(state, _), do: {{:error, :swapping_not_playing}, state}

  def cancel(%{swapping: %{next: tag} = s} = state) when tag != nil do
    case s.jobs[tag].phase do
      phase when phase in [:analysing, :opening, :ready] ->
        if phase != :analysing, do: Worker.cancel_next(state.worker, tag)

        if phase == :analysing do
          if s.starting do
            s = %{s | starting: %{s.starting | cancelled: true}}
            {{:ok, %{cancelling: tag}}, %{state | swapping: s}}
          else
            Worker.stop(s.preparer)
            state = drop_next(state, tag, "cancelled")
            {{:ok, status(state)}, state}
          end
        else
          {{:ok, %{cancelling: tag}}, state}
        end

      _ ->
        {{:error, :transition_in_progress}, state}
    end
  end

  def cancel(state), do: {{:ok, status(state)}, state}

  def starter_result(%{swapping: %{starting: %{ref: ref} = start} = s} = state, ref, result) do
    Process.demonitor(ref, [:flush])
    s = %{s | starting: nil}
    state = %{state | swapping: s}

    case result do
      {:ok, worker} ->
        if start.cancelled or s.next != start.tag do
          Worker.stop(worker)
          drop_next(state, start.tag, "cancelled")
        else
          state =
            put_in(state.swapping, %{
              s
              | preparer: worker,
                preparer_monitor: Process.monitor(worker)
            })

          if start.early, do: prepared(state, worker, start.early), else: state
        end

      _ ->
        drop_next(state, start.tag, "prepareFailed")
    end
  end

  def starter_result(state, _, _), do: state

  def preparer_event(%{swapping: s} = state, worker, ticket, event) when s != nil do
    cond do
      s.starting && s.starting.ticket == ticket ->
        case event do
          {:ready, metadata} -> put_in(state.swapping.starting.early, metadata)
          {:error, _} -> put_in(state.swapping.starting.cancelled, true)
          _ -> state
        end

      s.preparer == worker ->
        case event do
          {:ready, metadata} -> prepared(state, worker, metadata)
          {:error, _} -> drop_next(state, s.next, "prepareFailed")
          _ -> state
        end

      true ->
        state
    end
  end

  def preparer_event(state, _, _, _), do: state

  defp prepared(%{swapping: s} = state, _, metadata) do
    if s.next && s.jobs[s.next].phase == :analysing do
      tag = s.next

      job = %{
        s.jobs[tag]
        | analysis: metadata["analysis"],
          source_version: metadata[:source_version],
          phase: :opening
      }

      Worker.next(state.worker, job.track["info"]["identifier"], tag, job.analysis,
        filters: state.filters,
        source_version: job.source_version
      )

      put_in(state.swapping.jobs[tag], job)
    else
      state
    end
  end

  def ready(%{swapping: nil} = state, _), do: state

  def ready(%{swapping: s} = state, metadata) do
    update_in(
      state.swapping.jobs[s.current],
      &%{&1 | analysis: metadata["analysis"], source_version: metadata[:source_version]}
    )
  end

  def native(%{swapping: nil} = state, _), do: state

  def native(%{swapping: s} = state, %{"type" => type} = event) do
    tag = event["tag"]

    case {type, s.jobs[tag]} do
      {"settingsApplied", _} ->
        applied =
          if event["deferredTransition"],
            do: Map.merge(s.settings, Map.take(s.applied, ~w(autoMix fadeMs maxTempoChange))),
            else: s.settings

        put_in(state.swapping.applied, applied)

      {"nextReady", job} when job != nil ->
        applied =
          Map.merge(
            s.settings,
            Map.take(event["settings"] || s.applied, ~w(autoMix fadeMs maxTempoChange))
          )

        state = put_in(state.swapping.applied, applied)
        emit(state, "SwappingReadyEvent", %{tag: tag, track: job.track, plan: event["plan"]})
        put_in(state.swapping.jobs[tag], Map.merge(job, %{phase: :ready, plan: event["plan"]}))

      {"transitionStarted", job} when job != nil ->
        plan = event["plan"] || %{mode: "gapless"}
        emit(state, "SwappingTransitionEvent", %{tag: tag, track: job.track, plan: plan})
        put_in(state.swapping.jobs[tag], Map.merge(job, %{phase: :transitioning, plan: plan}))

      {"sourceRetired", job} when job != nil ->
        state = put_in(state.swapping.jobs[tag].retired, true)

        cond do
          event["cancelled"] ->
            drop_next(state, tag, "cancelled")

          tag != state.swapping.current and tag != state.swapping.next ->
            retire_public(state, tag)

          true ->
            state
        end

      {"prepareFailed", _} ->
        drop_next(state, tag, "prepareFailed")

      {"ended", job} when job != nil ->
        state = put_in(state.swapping.jobs[tag].ended, event["afterFrame"])
        ended(state)

      _ ->
        state
    end
  end

  def sent(%{swapping: nil} = state, _), do: state

  def sent(state, %{tag: tag, ordinal: ordinal}) do
    s = %{state.swapping | sent: ordinal}
    state = %{state | swapping: s}

    state =
      if tag != s.current and s.jobs[tag] do
        old = s.current
        if state.track, do: track_end(state, "finished")
        job = s.jobs[tag]
        Registry.unregister(Lixi.Registry, {:playing, state.session, state.guild})
        Registry.register(Lixi.Registry, {:playing, state.session, state.guild}, nil)
        Lixi.Metrics.playing(self(), true)
        emit_track(state, "TrackStartEvent", job.track)
        s = %{s | current: tag, next: nil}

        state = %{
          state
          | swapping: s,
            track: job.track,
            source_version: job.source_version,
            started: true,
            retries: [],
            end_time: nil
        }

        if old && s.jobs[old] && s.jobs[old].retired, do: retire_public(state, old), else: state
      else
        state
      end

    state
  end

  def sent(state, _), do: state

  def after_sent(%{swapping: s} = state) when s != nil, do: ended(state)
  def after_sent(state), do: state

  def tail?(%{swapping: s}) when s != nil,
    do: Enum.any?(s.jobs, fn {_, job} -> job.ended != nil end)

  def tail?(_), do: false

  def preparer_down(%{swapping: s} = state) do
    state = %{state | swapping: %{s | preparer: nil, preparer_monitor: nil}}

    if s.next && s.jobs[s.next].phase == :analysing,
      do: drop_next(state, s.next, "prepareFailed"),
      else: state
  end

  defp ended(%{swapping: %{current: tag} = s} = state) do
    job = s.jobs[tag]

    if (job && is_integer(job.ended)) and s.sent >= job.ended do
      if state.track, do: track_end(state, "finished")
      Lixi.Metrics.playing(self(), false)
      Registry.unregister(Lixi.Registry, {:playing, state.session, state.guild})

      state = %{
        state
        | track: nil,
          started: false,
          swapping: %{s | current: nil}
      }

      if job.retired, do: retire_public(state, tag), else: state
    else
      state
    end
  end

  def reset(state) do
    case Map.get(state, :swapping) do
      nil ->
        state

      s ->
        Worker.stop(s.preparer)
        if s.preparer_monitor, do: Process.demonitor(s.preparer_monitor, [:flush])
        starting = if s.starting, do: %{s.starting | cancelled: true}, else: nil

        retained =
          if s.current && s.jobs[s.current],
            do: %{s.current => %{s.jobs[s.current] | retired: false, ended: nil, phase: :playing}},
            else: %{}

        emit(state, "SwappingResetEvent", %{epoch: state.epoch + 1})

        %{
          state
          | swapping: %{
              s
              | preparer: nil,
                preparer_monitor: nil,
                next: nil,
                starting: starting,
                jobs: retained,
                sent: 0
            }
        }
    end
  end

  def clear(state) do
    state = reset(state)

    if s = Map.get(state, :swapping) do
      Lixi.Admission.release(s.prepare_lease)
      %{state | swapping: %{s | prepare_lease: nil, jobs: %{}, current: nil}}
    else
      state
    end
  end

  def close(state) do
    state = reset(state)

    if s = Map.get(state, :swapping) do
      Lixi.Admission.release(s.prepare_lease)
      Lixi.Plugins.Manager.checkin(s.plugin_lease)
    end

    state
  end

  defp drop_next(state, nil, _), do: state

  defp drop_next(%{swapping: s} = state, tag, reason) do
    if tag == s.next do
      Worker.stop(s.preparer)
      if s.preparer_monitor, do: Process.demonitor(s.preparer_monitor, [:flush])
      emit(state, "SwappingPrepareFailedEvent", %{tag: tag, reason: reason})
      job = s.jobs[tag]
      if job, do: emit(state, "SwappingRetiredEvent", %{tag: tag, track: job.track})

      %{
        state
        | swapping: %{
            s
            | next: nil,
              jobs: Map.delete(s.jobs, tag),
              preparer: nil,
              preparer_monitor: nil
          }
      }
    else
      state
    end
  end

  defp retire_public(%{swapping: s} = state, tag) do
    emit(state, "SwappingRetiredEvent", %{tag: tag, track: s.jobs[tag].track})
    put_in(state.swapping.jobs, Map.delete(s.jobs, tag))
  end

  defp job(track, phase),
    do: %{
      track: track,
      phase: phase,
      analysis: nil,
      source_version: nil,
      retired: false,
      ended: nil
    }

  defp tag, do: :erlang.unique_integer([:positive, :monotonic])

  defp emit(state, type, extra),
    do:
      Lixi.Sessions.emit_to(
        state.owner,
        state.session,
        Map.merge(%{op: "event", type: type, guildId: state.guild}, extra)
      )

  defp emit_track(state, type, track), do: emit(state, type, %{track: track})

  defp track_end(state, reason),
    do: emit(state, "TrackEndEvent", %{track: state.track, reason: reason})
end
