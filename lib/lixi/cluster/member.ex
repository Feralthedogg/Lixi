defmodule Lixi.Cluster.Member do
  use GenServer
  alias Lixi.Cluster.Coordinator
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    state = %{
      boot: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      timer: nil,
      plugins: []
    }

    {:ok, heartbeat(state)}
  end

  def handle_info(:heartbeat, state), do: {:noreply, heartbeat(state)}

  defp heartbeat(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {plugins, mode} =
      try do
        {Lixi.Plugins.Manager.catalogue(), Lixi.Lifecycle.mode()}
      catch
        :exit, _ -> {state.plugins, :recovering}
      end

    info = %{
      pid: self(),
      sessions_pid: Process.whereis(Lixi.Sessions),
      boot: state.boot,
      status: mode,
      players: DynamicSupervisor.count_children(Lixi.PlayerSupervisor).active,
      max_players: Application.fetch_env!(:lixi, :max_players),
      workers: Lixi.Admission.snapshot(),
      plugins: plugins,
      version: Lixi.Upgrade.version()
    }

    Coordinator.command({:instance, node(), info})
    %{state | timer: Process.send_after(self(), :heartbeat, 2_000), plugins: plugins}
  end
end
