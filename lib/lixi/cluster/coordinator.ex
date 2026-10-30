defmodule Lixi.Cluster.Coordinator do
  @moduledoc "Standalone or quorum-backed ownership directory, without media data in the log."
  use GenServer
  alias Lixi.Cluster.Machine
  @system :lixi_ra
  @server :lixi_metadata
  @local_snapshot {__MODULE__, :local_snapshot}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def enabled?, do: Application.get_env(:lixi, :cluster_enabled, false)
  def members, do: Enum.map(Application.get_env(:lixi, :cluster_nodes, []), &{@server, &1})

  def command(command) do
    if enabled?() do
      case :ra.process_command(members(), command, timeout()) do
        {:ok, result, _} -> result
        _ -> {:error, :unavailable}
      end
    else
      GenServer.call(__MODULE__, {:command, command})
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def query(query) do
    if enabled?() do
      case :ra.consistent_query(members(), {Machine, :query, [query]}, timeout()) do
        {:ok, result, _} -> {:ok, result}
        _ -> {:error, :unavailable}
      end
    else
      GenServer.call(__MODULE__, {:query, query})
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp timeout, do: Application.get_env(:lixi, :cluster_timeout, 1_000)

  @impl true
  def init(_) do
    if enabled?() do
      with true <- Node.alive?() and Application.get_env(:lixi, :cluster_nodes, []) != [],
           :ok <-
             if(node() in Application.get_env(:lixi, :cluster_nodes, []),
               do: start_raft(),
               else: :ok
             ) do
        {:ok, %{mode: :raft}}
      else
        false -> {:stop, :invalid_cluster_node}
        {:error, reason} -> {:stop, reason}
      end
    else
      {machine, index} = :persistent_term.get(@local_snapshot, {Machine.init(%{}), 0})
      effects = Machine.state_enter(:leader, machine)
      state = %{mode: :local, machine: machine, monitors: %{}, index: index}
      {:ok, apply_effects(state, effects)}
    end
  end

  defp start_raft do
    {:ok, _} = Application.ensure_all_started(:ra)
    directory = Application.fetch_env!(:lixi, :data_dir) |> Path.join("raft")

    config =
      :ra_system.default_config()
      |> Map.merge(%{
        name: @system,
        names: :ra_system.derive_names(@system),
        data_dir: String.to_charlist(directory),
        wal_data_dir: String.to_charlist(directory),
        wal_max_size_bytes: 1_048_576,
        wal_pre_allocate: false,
        segment_max_entries: 256,
        segment_max_size_bytes: 1_048_576
      })

    case :ra_system.start(config) do
      {:ok, _} -> start_server()
      {:error, {:already_started, _}} -> start_server()
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_server do
    id = {@server, node()}

    case :ra.restart_server(@system, id) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      _ ->
        case :ra.start_server(@system, :lixi_control, id, {:module, Machine, %{}}, members()) do
          :ok -> :ra.trigger_election(id)
          {:ok, _} -> :ra.trigger_election(id)
          error -> error
        end
    end
  end

  @impl true
  def handle_call({:query, query}, _, state),
    do: {:reply, {:ok, Machine.query(query, state.machine)}, state}

  def handle_call({:command, command}, _, state) do
    {machine, result, effects} = Machine.apply(%{index: state.index + 1}, command, state.machine)
    persist_local(state, machine)
    state = apply_effects(%{state | machine: machine, index: state.index + 1}, effects)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if state.monitors[pid] == ref do
      {machine, _, effects} =
        Machine.apply(%{index: state.index + 1}, {:down, pid, reason}, state.machine)

      persist_local(state, machine)

      {:noreply,
       apply_effects(
         %{
           state
           | machine: machine,
             monitors: Map.delete(state.monitors, pid),
             index: state.index + 1
         },
         effects
       )}
    else
      {:noreply, state}
    end
  end

  defp persist_local(state, machine) do
    # Heartbeats need no crash snapshot. Surviving media actors do need their claims and key ledger.
    if state.machine.names != machine.names or state.machine.keys != machine.keys or
         state.machine.plugins != machine.plugins do
      :persistent_term.put(@local_snapshot, {%{machine | instances: %{}}, state.index + 1})
    end
  end

  defp apply_effects(state, effects) do
    Enum.reduce(effects, state, fn
      {:monitor, :process, pid}, state ->
        if Map.has_key?(state.monitors, pid),
          do: state,
          else: put_in(state, [:monitors, pid], Process.monitor(pid))

      _, state ->
        state
    end)
  end
end
