defmodule Lixi.Admission do
  @moduledoc "Bounds native processes including probes; permits follow their monitored owner."
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def acquire, do: GenServer.call(__MODULE__, {:acquire, self()})
  def transfer(lease, owner), do: GenServer.call(__MODULE__, {:transfer, lease, owner})
  def release(lease), do: GenServer.call(__MODULE__, {:release, lease})
  def active, do: GenServer.call(__MODULE__, :active)
  def init(_), do: {:ok, %{}}

  def handle_call({:acquire, owner}, _, state) do
    if map_size(state) < Application.fetch_env!(:lixi, :max_workers) do
      lease = make_ref()
      {:reply, {:ok, lease}, Map.put(state, lease, Process.monitor(owner))}
    else
      {:reply, {:error, :worker_capacity}, state}
    end
  end

  def handle_call(:active, _, state), do: {:reply, map_size(state), state}

  def handle_call({:transfer, lease, owner}, _, state) do
    case state[lease] do
      nil ->
        {:reply, {:error, :expired}, state}

      monitor ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, Map.put(state, lease, Process.monitor(owner))}
    end
  end

  def handle_call({:release, lease}, _, state) do
    {monitor, state} = Map.pop(state, lease)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, state}
  end

  def handle_info({:DOWN, ref, _, _, _}, state),
    do: {:noreply, Map.reject(state, fn {_, monitor} -> monitor == ref end)}
end
