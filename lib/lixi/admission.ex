defmodule Lixi.Admission do
  @moduledoc "Independent playback/probe budgets; monitored leases can reserve a playback slot."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def acquire(purpose \\ :playback), do: GenServer.call(__MODULE__, {:acquire, purpose, self()})
  def reserve_swapping(lease), do: GenServer.call(__MODULE__, {:swapping, lease, self()})
  def transfer(lease, owner), do: GenServer.call(__MODULE__, {:transfer, lease, owner})
  def attach(lease, os_pid), do: GenServer.call(__MODULE__, {:attach, lease, os_pid, self()})
  def release(nil), do: :ok

  def release(lease) do
    :ets.update_element(__MODULE__, lease, {3, :released})
    GenServer.cast(__MODULE__, {:release, lease})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def snapshot do
    leases =
      for {lease, item, status} <- :ets.tab2list(__MODULE__),
          (status == :active and alive?(item)) or live_worker?(item),
          do: {lease, item}

    playback = Enum.count(leases, fn {_, item} -> item.purpose == :playback end)
    pids = for {_, item} <- leases, live_worker?(item), is_integer(item.os_pid), do: item.os_pid

    %{
      active: length(leases),
      playback: playback,
      probes: Enum.count(leases, fn {_, item} -> item.purpose == :probe end),
      preparers: Enum.count(leases, fn {_, item} -> item.purpose == :prepare end),
      max_playback: limit(:playback),
      max_probes: limit(:probe),
      max_preparers: limit(:prepare),
      os_pids: pids
    }
  end

  def active, do: snapshot().active

  def init(_) do
    entries = :ets.tab2list(__MODULE__)
    leases = Map.new(for {lease, item, _} <- entries, do: {lease, item})

    state =
      Map.new(prune(leases), fn {lease, item} ->
        item = %{
          item
          | monitor: Process.monitor(item.owner),
            worker_monitor: if(live_worker?(item), do: Process.monitor(item.worker), else: nil)
        }

        :ets.update_element(__MODULE__, lease, {2, item})
        {lease, item}
      end)

    {:ok, state}
  end

  def handle_call({:swapping, existing, owner}, _, state) do
    state = prune(state)

    existing_valid =
      existing == nil or
        (active?(existing) and match?(%{owner: ^owner, purpose: :playback}, state[existing]))

    purposes = if existing == nil, do: [:playback, :prepare], else: [:prepare]

    if existing_valid and
         Enum.all?(purposes, fn purpose ->
           Enum.count(state, fn {_, item} -> item.purpose == purpose end) < limit(purpose)
         end) do
      {leases, state} =
        Enum.map_reduce(purposes, state, fn purpose, acc ->
          {lease, item} = new_lease(purpose, owner)
          {lease, Map.put(acc, lease, item)}
        end)

      changed()
      [playback, prepare] = if existing == nil, do: leases, else: [existing | leases]
      {:reply, {:ok, playback, prepare}, state}
    else
      {:reply, {:error, :worker_capacity}, state}
    end
  end

  def handle_call({:acquire, purpose, owner}, _, state)
      when purpose in [:playback, :probe, :prepare] do
    state = prune(state)
    limit = limit(purpose)

    if Enum.count(state, fn {_, item} -> item.purpose == purpose end) < limit do
      {lease, item} = new_lease(purpose, owner)
      changed()
      {:reply, {:ok, lease}, Map.put(state, lease, item)}
    else
      {:reply, {:error, :worker_capacity}, state}
    end
  end

  def handle_call({:transfer, lease, owner}, _, state) do
    case state[lease] do
      nil ->
        {:reply, {:error, :expired}, state}

      item ->
        if active?(lease) do
          Process.demonitor(item.monitor, [:flush])
          item = %{item | owner: owner, monitor: Process.monitor(owner)}
          :ets.update_element(__MODULE__, lease, {2, item})
          {:reply, :ok, Map.put(state, lease, item)}
        else
          {:reply, {:error, :expired}, state}
        end
    end
  end

  def handle_call({:attach, lease, os_pid, worker}, _, state) do
    case state[lease] do
      nil ->
        {:reply, {:error, :expired}, state}

      item ->
        cond do
          not active?(lease) ->
            {:reply, {:error, :expired}, state}

          live_worker?(item) and item.worker != worker ->
            {:reply, {:error, :worker_active}, state}

          true ->
            if item.worker_monitor, do: Process.demonitor(item.worker_monitor, [:flush])

            item = %{
              item
              | os_pid: os_pid,
                worker: worker,
                worker_monitor: Process.monitor(worker)
            }

            :ets.update_element(__MODULE__, lease, {2, item})
            {:reply, :ok, Map.put(state, lease, item)}
        end
    end
  end

  def handle_cast({:release, _lease}, state) do
    changed()
    {:noreply, prune(state)}
  end

  def handle_info({:DOWN, ref, _, _, _}, state) do
    state =
      Map.new(state, fn {lease, item} ->
        item =
          if item.worker_monitor == ref,
            do: %{item | worker: nil, worker_monitor: nil, os_pid: nil},
            else: item

        :ets.update_element(__MODULE__, lease, {2, item})
        {lease, item}
      end)

    changed()
    {:noreply, prune(state)}
  end

  defp prune(state) do
    Map.reject(state, fn {lease, item} ->
      if (alive?(item) and active?(lease)) or live_worker?(item) do
        false
      else
        demonitor(item)
        :ets.delete(__MODULE__, lease)
        true
      end
    end)
  end

  defp active?(lease) do
    case :ets.lookup(__MODULE__, lease) do
      [{_, _, :active}] -> true
      _ -> false
    end
  end

  defp alive?(item), do: Process.alive?(item.owner) or live_worker?(item)
  defp live_worker?(%{worker: worker}), do: is_pid(worker) and Process.alive?(worker)

  defp demonitor(item) do
    Process.demonitor(item.monitor, [:flush])
    if item.worker_monitor, do: Process.demonitor(item.worker_monitor, [:flush])
  end

  defp limit(:playback), do: Application.fetch_env!(:lixi, :max_workers)
  defp limit(:probe), do: Application.fetch_env!(:lixi, :max_probe_workers)
  defp limit(:prepare), do: Application.get_env(:lixi, :max_preparers, 10)

  defp new_lease(purpose, owner) do
    lease = make_ref()

    item = %{
      owner: owner,
      monitor: Process.monitor(owner),
      purpose: purpose,
      os_pid: nil,
      worker: nil,
      worker_monitor: nil
    }

    :ets.insert(__MODULE__, {lease, item, :active})
    {lease, item}
  end

  defp changed do
    if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
  end
end
