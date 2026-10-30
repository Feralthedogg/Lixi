defmodule Lixi.Audio.Worker do
  @moduledoc "Port owner with bounded credits and one asynchronous 64 KiB read per source slot."
  use GenServer
  import Bitwise

  def next(pid, identifier, tag, analysis, options),
    do: GenServer.cast(pid, {:next, identifier, tag, analysis, options})

  def cancel_next(pid, tag), do: GenServer.cast(pid, {:native, 12, <<tag::64>>})
  def settings(pid, settings), do: GenServer.cast(pid, {:native, 13, Jason.encode!(settings)})
  def skip(pid), do: GenServer.cast(pid, {:native, 14, <<>>})

  def start(owner, identifier, epoch, options \\ []) do
    permit =
      case Keyword.get(options, :lease) do
        nil -> Lixi.Admission.acquire(Keyword.get(options, :purpose, :playback))
        lease -> {:ok, lease}
      end

    with {:ok, lease} <- permit do
      case GenServer.start(__MODULE__, {owner, identifier, epoch, options, lease}) do
        {:ok, pid} ->
          case if(Keyword.has_key?(options, :lease),
                 do: :ok,
                 else: Lixi.Admission.transfer(lease, pid)
               ) do
            :ok ->
              {:ok, pid}

            error ->
              stop(pid)
              error
          end

        error ->
          if not Keyword.has_key?(options, :lease), do: Lixi.Admission.release(lease)
          error
      end
    end
  end

  def grant(pid, limit), do: GenServer.cast(pid, {:grant, limit})

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 8_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  def stop(_), do: :ok

  def executable do
    packaged = Application.app_dir(:lixi, "priv/bin/lixi-audio")

    Application.get_env(:lixi, :audio_executable) ||
      if(File.regular?(packaged),
        do: packaged,
        else: Path.expand("../../../native/audio_engine/target/debug/lixi-audio", __DIR__)
      )
  end

  @impl true
  def init({owner, identifier, epoch, options, lease}) do
    Process.flag(:trap_exit, true)

    with true <- File.regular?(executable()),
         :ok <- Lixi.Admission.attach(lease, nil),
         {:ok, source} <- Lixi.Source.start_link(identifier) do
      description = Lixi.Source.describe(source)
      expected = Keyword.get(options, :source_version)

      if expected != nil and expected != description.version,
        do: send(self(), {:command_error, :source_changed})

      generation = :erlang.unique_integer([:positive, :monotonic])
      stream = :crypto.strong_rand_bytes(16)
      context = <<stream::binary, generation::64, epoch::64>>

      port =
        Port.open({:spawn_executable, executable()}, [
          :binary,
          {:packet, 4},
          :exit_status,
          :use_stdio
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      :ok = Lixi.Admission.attach(lease, os_pid)

      state = %{
        lease: lease,
        managed_lease: Keyword.has_key?(options, :lease),
        prepare_only: Keyword.get(options, :mode) == "prepare",
        ready_timer:
          Process.send_after(
            self(),
            :open_timeout,
            if(Keyword.has_key?(options, :swapping), do: 60_000, else: 10_000)
          ),
        port: port,
        source: source,
        source_version: description.version,
        protected_tags: MapSet.new([Keyword.get(options, :tag, 0)]),
        failed_tags: MapSet.new(),
        slots: %{
          0 => %{pid: source, version: description.version, tag: Keyword.get(options, :tag, 0)}
        },
        tasks: %{},
        opening: nil,
        retired: %{0 => 0, 1 => 0},
        owner: owner,
        monitor: Process.monitor(owner),
        epoch: epoch,
        context: context,
        limit: 0,
        produced: 0,
        reads: %{},
        pending: %{},
        ended: false
      }

      open = %{
        length: description.length,
        extension: description.extension,
        position: Keyword.get(options, :position, 0),
        gain: Keyword.get(options, :gain, 1.0),
        filters: Keyword.get(options, :filters, %{}),
        end_time: Keyword.get(options, :end_time),
        swapping: Keyword.get(options, :swapping),
        mode: Keyword.get(options, :mode),
        tag: Keyword.get(options, :tag, 0),
        report: Keyword.get(options, :report)
      }

      {:ok, command(state, 1, 0, Jason.encode!(open))}
    else
      false -> {:stop, :audio_engine_not_built}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:grant, limit}, state)
      when limit >= state.limit and limit <= state.produced + 25 do
    {:noreply, command(%{state | limit: limit}, 7, 0, <<limit::64>>)}
  end

  def handle_cast({:grant, _}, state), do: fail(state, :credit_limit)
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  def handle_cast({:native, 12, <<tag::64>>}, %{opening: %{tag: tag} = job} = state),
    do: {:noreply, %{state | opening: Map.put(job, :cancelled, true)}}

  def handle_cast({:native, type, payload}, state),
    do: {:noreply, command(state, type, 0, payload)}

  def handle_cast({:next, identifier, tag, analysis, options}, state) do
    slot = Enum.find(0..1, &(not Map.has_key?(state.slots, &1)))

    if slot != nil and state.opening == nil do
      owner = self()

      task =
        Task.Supervisor.async_nolink(Lixi.TaskSupervisor, fn ->
          with {:ok, source} <- Lixi.Source.start(identifier, owner) do
            {:ok, source, Lixi.Source.describe(source)}
          end
        end)

      job = %{slot: slot, tag: tag, analysis: analysis, options: options, ref: task.ref}

      {:noreply,
       %{state | opening: job, tasks: Map.put(state.tasks, task.ref, {:open, task.pid})}}
    else
      notify(
        state,
        {:swapping,
         %{"type" => "prepareFailed", "tag" => tag, "message" => "Source slots occupied"}}
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {port,
         {:data, <<1, type, 0::16, context::binary-size(32), request::64, payload::binary>>}},
        %{port: port, context: context} = state
      )
      when byte_size(payload) <= 131_028 do
    packet(type, request, payload, state)
  end

  def handle_info({port, {:data, _}}, %{port: port} = state), do: fail(state, :invalid_packet)

  def handle_info({port, {:exit_status, _}}, %{port: port, ended: true} = state),
    do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: fail(state, {:worker_exit, code})

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, source, reason}, state) when is_pid(source) do
    case Enum.find(state.slots, fn {_, item} -> item.pid == source end) do
      nil ->
        {:noreply, state}

      {slot, item} ->
        if state.prepare_only or MapSet.member?(state.protected_tags, item.tag) do
          fail(state, {:source_exit, reason})
        else
          # Wait for native cancellation acknowledgement before retiring job metadata.
          # A transition already rendered can reject cancellation.
          state = abort_reads(state, slot, source)
          state = %{state | failed_tags: MapSet.put(state.failed_tags, item.tag)}
          {:noreply, command(state, 12, 0, <<item.tag::64>>)}
        end
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {kind, tasks} ->
        Process.demonitor(ref, [:flush])
        task_result(kind, result, %{state | tasks: tasks})
    end
  end

  def handle_info({:DOWN, ref, _, _, _}, %{monitor: ref} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} -> {:noreply, state}
      {kind, tasks} -> task_result(kind, {:error, reason}, %{state | tasks: tasks})
    end
  end

  def handle_info(:open_timeout, state), do: fail(state, :load_timeout)

  def handle_info(:retry, state) do
    pending = state.pending
    state = %{state | pending: %{}}

    state =
      Enum.reduce(pending, state, fn {{type, request}, {payload, attempts}}, acc ->
        command(acc, type, request, payload, attempts + 1)
      end)

    {:noreply, state}
  end

  def handle_info({:command_error, reason}, state), do: fail(state, reason)

  defp packet(2, _, payload, state) do
    case Jason.decode(payload) do
      {:ok, metadata} when is_map(metadata) ->
        Process.cancel_timer(state.ready_timer)
        notify(state, {:ready, Map.put(metadata, :source_version, state.source_version)})

        state =
          if state.prepare_only,
            do: Enum.reduce(Map.keys(state.slots), state, &retire(&2, &1)),
            else: state

        {:noreply, state}

      _ ->
        fail(state, :invalid_metadata)
    end
  end

  defp packet(3, request, <<offset::64, length::32>>, state) when length in 1..65_536 do
    slot = request >>> 63
    source = state.slots[slot]

    if source && not Enum.any?(state.reads, fn {_, value} -> value == slot end) do
      task =
        Task.Supervisor.async_nolink(Lixi.TaskSupervisor, fn ->
          Lixi.Source.read(source.pid, offset, length)
        end)

      {:noreply,
       %{
         state
         | reads: Map.put(state.reads, request, slot),
           tasks: Map.put(state.tasks, task.ref, {:read, task.pid, request, source.pid})
       }}
    else
      fail(state, :read_budget_exceeded)
    end
  end

  defp packet(8, request, <<>>, state) do
    if Map.has_key?(state.reads, request) or request <= state.retired[request >>> 63],
      do: {:noreply, %{state | reads: Map.delete(state.reads, request)}},
      else: fail(state, :invalid_release)
  end

  defp packet(5, _, <<position::64, valid::16, opus::binary>>, state)
       when state.produced < state.limit and valid in 1..960 and byte_size(opus) in 1..1024 do
    notify(state, {:frame, %{opus: opus, position: position, valid_samples: valid}})
    {:noreply, %{state | produced: state.produced + 1}}
  end

  defp packet(16, _, <<tag::64, position::64, valid::16, opus::binary>>, state)
       when state.produced < state.limit and valid in 1..960 and byte_size(opus) in 1..1024 do
    notify(
      state,
      {:frame,
       %{
         opus: opus,
         position: position,
         valid_samples: valid,
         tag: tag,
         ordinal: state.produced + 1
       }}
    )

    {:noreply, %{state | produced: state.produced + 1}}
  end

  defp packet(17, _, payload, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type, "tag" => tag, "slot" => slot} = event}
      when type in ["sourceRetired", "prepareFailed"] and slot in 0..1 ->
        state = if match?(%{tag: ^tag}, state.slots[slot]), do: retire(state, slot), else: state

        event =
          if MapSet.member?(state.failed_tags, tag),
            do: Map.put(event, "type", "prepareFailed"),
            else: event

        state = %{
          state
          | failed_tags: MapSet.delete(state.failed_tags, tag),
            protected_tags: MapSet.delete(state.protected_tags, tag)
        }

        notify(state, {:swapping, event})
        {:noreply, state}

      {:ok, %{"type" => _} = event} ->
        state =
          if event["type"] == "transitionStarted",
            do: %{state | protected_tags: MapSet.put(state.protected_tags, event["tag"])},
            else: state

        notify(state, {:swapping, event})
        {:noreply, state}

      _ ->
        fail(state, :invalid_metadata)
    end
  end

  defp packet(6, _, <<>>, state) do
    notify(state, :end)
    {:noreply, %{state | ended: true}}
  end

  defp packet(9, _, payload, state) do
    message =
      case Jason.decode(payload) do
        {:ok, %{"message" => message}} -> String.slice(message, 0, 512)
        _ -> "Audio engine failure"
      end

    fail(state, message)
  end

  defp packet(_, _, _, state), do: fail(state, :protocol_violation)

  defp task_result({:read, _, request, source}, result, state) do
    if match?(%{pid: ^source}, state.slots[request >>> 63]) and Map.has_key?(state.reads, request) do
      bytes =
        case result do
          {:ok, bytes} when is_binary(bytes) -> bytes
          _ -> <<>>
        end

      {:noreply, command(state, 4, request, bytes)}
    else
      {:noreply, state}
    end
  end

  defp task_result({:open, _}, result, %{opening: job} = state) do
    state = %{state | opening: nil}

    case result do
      {:ok, source, desc} ->
        expected = Keyword.get(job.options, :source_version)

        if Map.get(job, :cancelled, false) or (expected != nil and expected != desc.version) do
          Lixi.Source.close(source)

          notify(
            state,
            {:swapping,
             %{
               "type" => "sourceRetired",
               "tag" => job.tag,
               "slot" => job.slot,
               "cancelled" => true
             }}
          )

          {:noreply, state}
        else
          Process.link(source)
          entry = %{pid: source, version: desc.version, tag: job.tag}

          open = %{
            length: desc.length,
            extension: desc.extension,
            position: 0,
            gain: 1.0,
            filters: Keyword.get(job.options, :filters, %{})
          }

          payload =
            Jason.encode!(%{slot: job.slot, tag: job.tag, open: open, analysis: job.analysis})

          {:noreply,
           command(%{state | slots: Map.put(state.slots, job.slot, entry)}, 11, 0, payload)}
        end

      _ ->
        notify(
          state,
          {:swapping,
           %{"type" => "prepareFailed", "tag" => job.tag, "message" => "Source open failed"}}
        )

        {:noreply, state}
    end
  end

  defp retire(state, slot) do
    {entry, slots} = Map.pop(state.slots, slot)
    if entry, do: Lixi.Source.close(entry.pid)
    {retired_reads, reads} = Enum.split_with(state.reads, fn {_, value} -> value == slot end)

    retired =
      Enum.reduce(retired_reads, state.retired[slot], fn {request, _}, last ->
        max(request, last)
      end)

    tasks =
      Map.reject(state.tasks, fn {ref, task} ->
        if entry && match?({:read, _, _, pid} when pid == entry.pid, task) do
          Process.demonitor(ref, [:flush])
          Process.exit(elem(task, 1), :kill)
          true
        else
          false
        end
      end)

    %{
      state
      | slots: slots,
        tasks: tasks,
        reads: Map.new(reads),
        retired: Map.put(state.retired, slot, retired)
    }
  end

  defp abort_reads(state, slot, source) do
    state =
      Enum.reduce(state.reads, state, fn {request, read_slot}, acc ->
        if read_slot == slot, do: command(acc, 4, request, <<>>), else: acc
      end)

    tasks =
      Map.reject(state.tasks, fn {ref, task} ->
        if match?({:read, _, _, ^source}, task) do
          Process.demonitor(ref, [:flush])
          Process.exit(elem(task, 1), :kill)
          true
        else
          false
        end
      end)

    %{state | tasks: tasks}
  end

  defp command(state, type, request, payload, attempts \\ 0) do
    header = <<1, type, 0::16, state.context::binary, request::64>>
    bytes = if type == 4, do: [header, payload], else: <<header::binary, payload::binary>>

    cond do
      attempts >= 20 or map_size(state.pending) >= 4 ->
        send(self(), {:command_error, :port_busy})
        state

      port_command(state.port, bytes) ->
        state

      true ->
        if map_size(state.pending) == 0, do: Process.send_after(self(), :retry, 5)
        %{state | pending: Map.put(state.pending, {type, request}, {payload, attempts})}
    end
  end

  defp port_command(port, bytes) do
    Port.command(port, bytes, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  defp notify(state, event), do: send(state.owner, {:audio, self(), state.epoch, event})

  defp fail(state, reason) do
    notify(state, {:error, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    if not state.managed_lease, do: Lixi.Admission.release(state.lease)
    for {_, source} <- state.slots, do: Lixi.Source.close(source.pid)
    for {_, task} <- state.tasks, do: Process.exit(elem(task, 1), :kill)
  end
end
