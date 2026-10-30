defmodule Lixi.Lifecycle do
  @moduledoc "Controls admission while keeping existing sessions and audio processes running."
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, :accepting, name: __MODULE__)
  def mode, do: GenServer.call(__MODULE__, :mode)
  def accepting?, do: mode() == :accepting
  def drain, do: GenServer.call(__MODULE__, {:mode, :draining})
  def resume, do: GenServer.call(__MODULE__, {:mode, :accepting})
  def upgrade_start, do: GenServer.call(__MODULE__, {:mode, :upgrading})
  @impl true
  def init(mode), do: {:ok, mode}
  @impl true
  def handle_call(:mode, _, mode), do: {:reply, mode, mode}

  def handle_call({:mode, :accepting}, _, mode) do
    if Lixi.Upgrade.status().recovery_required do
      {:reply, {:error, :recovery_required}, mode}
    else
      if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
      {:reply, {:ok, mode}, :accepting}
    end
  end

  def handle_call({:mode, mode}, _, old) do
    if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
    {:reply, {:ok, old}, mode}
  end

  def status do
    mode = mode()
    players = DynamicSupervisor.count_children(Lixi.PlayerSupervisor).active
    sessions = Lixi.Sessions.local_metrics().sessions

    voices =
      Registry.select(Lixi.Registry, [{{{:voice_sender, :_, :_}, :_, :_}, [], [true]}])
      |> length()

    workers = Lixi.Admission.active()
    callbacks = DynamicSupervisor.count_children(Lixi.PluginCallSupervisor).active
    events = Lixi.Events.pending()

    %{
      mode: mode,
      local_players: players,
      local_sessions: sessions,
      local_voice_senders: voices,
      local_workers: workers,
      local_plugin_callbacks: callbacks,
      pending_events: events,
      safe_to_stop:
        mode == :draining and players == 0 and sessions == 0 and voices == 0 and workers == 0 and
          callbacks == 0 and events == 0
    }
  end

  @impl true
  def code_change(_, mode, _), do: {:ok, mode}
end
