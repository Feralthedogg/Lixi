defmodule Lixi.Events do
  @moduledoc "Bounded, acknowledged control events; audio never waits for cluster lookup."
  use GenServer
  @table __MODULE__
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def pending, do: :ets.lookup_element(@table, :budget, 2)

  def emit(owner, session, event) do
    if (event[:op] || event["op"]) in ["playerUpdate", "stats"] do
      :erlang.send(owner, {:"$gen_cast", {:emit, session, event}}, [:nosuspend, :noconnect])
    else
      bytes = :erlang.external_size(event)
      [count, total] = :ets.update_counter(@table, :budget, [{2, 1}, {3, bytes}])

      if count <= 4096 and total <= 8_388_608 do
        GenServer.cast(__MODULE__, {:event, owner, session, event, bytes})
      else
        :ets.update_counter(@table, :budget, [{2, -1}, {3, -bytes}])
        :erlang.send(owner, {:event_overflow, session}, [:nosuspend, :noconnect])
        {:error, :event_capacity}
      end
    end
  end

  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@table, {:budget, 0, 0})
    Process.send_after(self(), :retry, 200)
    {:ok, %{queues: %{}, pending: %{}}}
  end

  def handle_cast({:event, owner, session, event, bytes}, state) do
    id = make_ref()
    entry = %{id: id, owner: owner, session: session, event: event, bytes: bytes}
    queue = :queue.in(id, Map.get(state.queues, session, :queue.new()))

    state = %{
      state
      | queues: Map.put(state.queues, session, queue),
        pending: Map.put(state.pending, id, entry)
    }

    send_head(state, session)
    {:noreply, state}
  end

  def handle_info({:event_ack, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        :ets.update_counter(@table, :budget, [{2, -1}, {3, -entry.bytes}])
        {{:value, ^id}, queue} = :queue.out(state.queues[entry.session])

        queues =
          if :queue.is_empty(queue),
            do: Map.delete(state.queues, entry.session),
            else: Map.put(state.queues, entry.session, queue)

        state = %{state | queues: queues, pending: pending}
        send_head(state, entry.session)
        {:noreply, state}
    end
  end

  def handle_info({:event_redirect, id, owner}, state) do
    case state.pending[id] do
      nil ->
        {:noreply, state}

      entry ->
        state = put_in(state, [:pending, id], %{entry | owner: owner})
        send_head(state, entry.session)
        {:noreply, state}
    end
  end

  def handle_info(:retry, state) do
    Enum.each(Map.keys(state.queues), fn session ->
      case Lixi.Cluster.lookup({:session, session}) do
        {:ok, owner} ->
          {:value, id} = :queue.peek(state.queues[session])
          send(self(), {:event_redirect, id, owner})

        {:error, :not_found} ->
          for id <- :queue.to_list(state.queues[session]), do: send(self(), {:event_ack, id})

        _ ->
          :ok
      end
    end)

    Process.send_after(self(), :retry, 200)
    {:noreply, state}
  end

  defp send_head(state, session) do
    with queue when not is_nil(queue) <- state.queues[session],
         {:value, id} <- :queue.peek(queue) do
      entry = state.pending[id]

      :erlang.send(entry.owner, {:deliver_event, id, self(), session, entry.event}, [
        :nosuspend,
        :noconnect
      ])
    end
  end
end
