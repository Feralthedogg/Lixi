defmodule Lixi.Audio.Worker do
  @moduledoc "Port owner. One stream, bounded credits and a single outstanding 64 KiB read."
  use GenServer

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
        ready_timer: Process.send_after(self(), :open_timeout, 10_000),
        port: port,
        source: source,
        source_version: description.version,
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
        end_time: Keyword.get(options, :end_time)
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

  def handle_info({:EXIT, source, reason}, %{source: source} = state),
    do: fail(state, {:source_exit, reason})

  def handle_info({:DOWN, ref, _, _, _}, %{monitor: ref} = state), do: {:stop, :normal, state}

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
        {:noreply, state}

      _ ->
        fail(state, :invalid_metadata)
    end
  end

  defp packet(3, request, <<offset::64, length::32>>, state)
       when length in 1..65_536 and map_size(state.reads) == 0 do
    case Lixi.Source.read(state.source, offset, length) do
      {:ok, bytes} ->
        {:noreply, command(%{state | reads: %{request => byte_size(bytes)}}, 4, request, bytes)}

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp packet(8, request, <<>>, state) do
    if Map.has_key?(state.reads, request),
      do: {:noreply, %{state | reads: Map.delete(state.reads, request)}},
      else: fail(state, :invalid_release)
  end

  defp packet(5, _, <<position::64, valid::16, opus::binary>>, state)
       when state.produced < state.limit and valid in 1..960 and byte_size(opus) in 1..1024 do
    notify(state, {:frame, %{opus: opus, position: position, valid_samples: valid}})
    {:noreply, %{state | produced: state.produced + 1}}
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
    if Process.alive?(state.source), do: GenServer.stop(state.source, :normal, 7_000)
  end
end
