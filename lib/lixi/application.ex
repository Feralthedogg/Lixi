defmodule Lixi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    for path <- Application.get_env(:lixi, :plugin_paths, []) do
      {:ok, %{type: :directory}} = File.lstat(path)
      true = Code.append_path(path)
    end

    :ok = Lixi.Upgrade.bootstrap()

    children = [
      {Registry, keys: :unique, name: Lixi.Registry},
      {Task.Supervisor, name: Lixi.TaskSupervisor},
      Lixi.Cluster.Coordinator,
      Lixi.Lifecycle,
      Lixi.Events,
      Lixi.Cluster.Owners,
      {DynamicSupervisor,
       strategy: :one_for_one, name: Lixi.PluginCallSupervisor, max_children: 8},
      Lixi.Plugins.Manager,
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Lixi.PlayerSupervisor,
       max_children: Application.fetch_env!(:lixi, :max_players)},
      Lixi.Admission,
      Lixi.Sessions,
      Lixi.Upgrade,
      Lixi.Cluster.Member
    ]

    children =
      if Application.get_env(:lixi, :start_server, true) do
        children ++
          [
            {Bandit,
             plug: Lixi.Router,
             port: Application.fetch_env!(:lixi, :port),
             ip: Application.fetch_env!(:lixi, :ip)}
          ]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Lixi.Supervisor)
  end
end
