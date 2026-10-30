defmodule Lixi.Cluster.Owners do
  @moduledoc "Reconciles session owners off the audio clock, one bounded batch at a time."
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def watch(player, session), do: GenServer.cast(__MODULE__, {:watch, player, session})
  def refresh, do: send(__MODULE__, :refresh)

  def init(_) do
    Process.send_after(self(), :refresh, 1_000)

    entries =
      Registry.select(Lixi.Registry, [{{{:player, :"$1", :_}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}])

    for {pid, _} <- entries, do: Process.monitor(pid)
    {:ok, %{players: Map.new(entries), task: nil}}
  end

  def handle_cast({:watch, player, session}, state) do
    if not Map.has_key?(state.players, player), do: Process.monitor(player)
    {:noreply, put_in(state, [:players, player], session)}
  end

  def handle_info(:refresh, %{task: nil} = state) do
    sessions = Map.values(state.players) |> Enum.uniq()

    task =
      Task.Supervisor.async_nolink(Lixi.TaskSupervisor, fn ->
        result =
          Lixi.Cluster.Coordinator.query({:lookup_many, Enum.map(sessions, &{:session, &1})})

        {sessions, result}
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({ref, {sessions, {:ok, result}}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    for {player, session} <- state.players, session in sessions do
      case result.entries[{:session, session}] do
        %{owner: owner, token: epoch} ->
          if node(owner) != node(), do: Node.connect(node(owner))
          send(player, {:session_authority, owner, epoch})

        nil ->
          send(player, {:session_missing, result.revision})
      end
    end

    Process.send_after(self(), :refresh, 1_000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({ref, _}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :refresh, 1_000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{task: %{ref: ref}} = state) do
    Process.send_after(self(), :refresh, 1_000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, _, _, pid, _}, state),
    do: {:noreply, %{state | players: Map.delete(state.players, pid)}}
end
