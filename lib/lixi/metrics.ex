defmodule Lixi.Metrics do
  @moduledoc "Sampled OS usage and a rolling minute of audio delivery counters."
  use GenServer
  alias Lixi.Metrics.Process, as: Processes

  @counters [
    :sent,
    :nulled,
    :late,
    :expired,
    :underruns,
    :send_errors,
    :voice_reconnects,
    :dave_transitions,
    :dave_ready
  ]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def playing(pid, active), do: GenServer.cast(__MODULE__, {:playing, pid, active})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def record(counter, count \\ 1) when counter in @counters do
    :ets.update_counter(__MODULE__, counter, {2, count}, {counter, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    for key <- @counters, do: :ets.insert(__MODULE__, {key, 0})
    now = System.monotonic_time(:millisecond)

    state = %{
      process_units: Processes.units(),
      players: %{},
      active_us: 0,
      previous: %{},
      at: now,
      history: :queue.new(),
      snapshot: %{},
      timer: nil
    }

    playing = Registry.select(Lixi.Registry, [{{{:playing, :_, :_}, :"$1", :_}, [], [:"$1"]}])

    state = %{
      state
      | players:
          Map.new(playing, &{&1, {Process.monitor(&1), System.monotonic_time(:microsecond)}})
    }

    {:ok, sample(state)}
  end

  def handle_call(:snapshot, _, state), do: {:reply, state.snapshot, state}

  def handle_cast({:playing, pid, true}, state) do
    if Map.has_key?(state.players, pid) do
      {:noreply, state}
    else
      entry = {Process.monitor(pid), System.monotonic_time(:microsecond)}
      {:noreply, %{state | players: Map.put(state.players, pid, entry)}}
    end
  end

  def handle_cast({:playing, pid, false}, state), do: {:noreply, stopped(state, pid)}
  def handle_info({:DOWN, _, :process, pid, _}, state), do: {:noreply, stopped(state, pid)}
  def handle_info(:sample, state), do: {:noreply, sample(state)}

  defp stopped(state, pid) do
    case Map.pop(state.players, pid) do
      {nil, _} ->
        state

      {{ref, since}, players} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | players: players,
            active_us: state.active_us + System.monotonic_time(:microsecond) - since
        }
    end
  end

  defp sample(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = System.monotonic_time(:millisecond)
    admission = Lixi.Admission.snapshot()
    beam_pid = String.to_integer(System.pid())
    processes = Processes.sample([beam_pid | admission.os_pids], state.process_units)
    native = Map.delete(processes, beam_pid)
    native_rss = Enum.reduce(native, 0, fn {_, item}, sum -> sum + item.rss end)

    cores =
      case :erlang.system_info(:logical_processors_available) do
        count when is_integer(count) and count > 0 -> count
        _ -> System.schedulers_online()
      end

    cpu = Processes.cpu_delta(processes, state.previous) / max(now - state.at, 1) / cores
    totals = Map.new(@counters, &{&1, :ets.lookup_element(__MODULE__, &1, 2)})

    active_us =
      Enum.reduce(state.players, state.active_us, fn {_, {_, since}}, total ->
        total + now * 1000 - since
      end)

    totals = Map.put(totals, :expected, div(max(active_us, 0), 20_000))
    history = :queue.in({now, totals}, state.history) |> trim(now - 60_000)
    {old_at, oldest} = :queue.head(history)
    frames = Map.new(totals, fn {key, value} -> {key, value - Map.get(oldest, key, 0)} end)
    frames = Map.put(frames, :deficit, frames.expected - frames.sent - frames.nulled)
    {system_load, basis} = system_load(cores)

    snapshot = %{
      sampleTime: System.system_time(:millisecond),
      sampleIntervalMs: max(now - state.at, 0),
      windowMs: now - old_at,
      cpu: cpu,
      cores: cores,
      systemLoad: system_load,
      systemLoadBasis: basis,
      nativeRss: native_rss,
      beamRss: get_in(processes, [beam_pid, :rss]),
      nativeProcesses: map_size(native),
      expectedNativeProcesses: length(admission.os_pids),
      processSamplesComplete: map_size(processes) == length(admission.os_pids) + 1,
      workers: Map.delete(admission, :os_pids),
      totals: Map.delete(totals, :expected),
      frames: frames
    }

    timer = Process.send_after(self(), :sample, 1_000)
    %{state | previous: processes, at: now, history: history, snapshot: snapshot, timer: timer}
  end

  defp trim(history, cutoff) do
    case :queue.out(history) do
      {{:value, {at, _}}, rest} ->
        case :queue.peek(rest) do
          {:value, {next, _}} when at < cutoff and next <= cutoff -> trim(rest, cutoff)
          _ -> history
        end

      _ ->
        history
    end
  end

  defp system_load(cores) do
    if :os.type() in [{:unix, :linux}, {:unix, :freebsd}, {:unix, :openbsd}, {:unix, :sunos}] do
      case :cpu_sup.util() do
        value when is_number(value) -> {value / 100, "cpuUtilization"}
        _ -> {:cpu_sup.avg1() / 256 / cores, "oneMinuteLoadAverage"}
      end
    else
      {:cpu_sup.avg1() / 256 / cores, "oneMinuteLoadAverage"}
    end
  end
end
