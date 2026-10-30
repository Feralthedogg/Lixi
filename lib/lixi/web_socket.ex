defmodule Lixi.WebSocket do
  @behaviour WebSock
  @impl true
  def init({user, previous}) do
    case Lixi.Sessions.connect(user, self(), previous) do
      {:ok, id, resumed, events} ->
        Process.send_after(self(), :stats, 60_000)

        frames =
          for event <- [%{op: "ready", resumed: resumed, sessionId: id} | events],
              do: {:text, Jason.encode!(event)}

        {:ok, owner} = Lixi.Cluster.lookup({:session, id})
        {:push, frames, %{session: id, owner: owner, monitor: Process.monitor(owner)}}

      {:error, :capacity} ->
        {:stop, {:shutdown, :capacity}, {1013, "Session capacity reached"}, %{}}

      {:error, _} ->
        {:stop, {:shutdown, :unavailable}, {1013, "Instance unavailable"}, %{}}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :text]}, state), do: {:ok, state}
  def handle_in(_, state), do: {:ok, state}
  @impl true
  def handle_info({:lixi_event, event}, state), do: {:push, {:text, Jason.encode!(event)}, state}

  def handle_info(:stats, state) do
    Process.send_after(self(), :stats, 60_000)
    {:push, {:text, Jason.encode!(Map.put(Lixi.Info.stats(), "op", "stats"))}, state}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{monitor: ref} = state),
    do: {:stop, {:shutdown, :session_owner_lost}, {1012, "Session owner unavailable"}, state}

  def handle_info({:session_owner_changed, id, owner}, %{session: id} = state) do
    Process.demonitor(state.monitor, [:flush])
    {:ok, %{state | owner: owner, monitor: Process.monitor(owner)}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
