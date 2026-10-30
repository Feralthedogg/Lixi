defmodule Lixi.Info do
  def version, do: "4.0.0+lixi.#{Lixi.Upgrade.version()}"

  def get do
    %{
      "version" => %{
        "semver" => version(),
        "major" => 4,
        "minor" => 0,
        "patch" => 0,
        "preRelease" => nil,
        "build" => "lixi.#{Lixi.Upgrade.version()}"
      },
      "buildTime" => 0,
      "git" => %{"branch" => "unknown", "commit" => "unknown", "commitTime" => 0},
      "jvm" => "BEAM OTP #{System.otp_release()} / Elixir #{System.version()}",
      "lavaplayer" => "lixi-audio/0.1.0",
      "sourceManagers" =>
        if(Application.get_env(:lixi, :http_sources), do: ["local", "http"], else: ["local"]),
      "filters" => Lixi.Filters.supported(),
      "plugins" => Lixi.Plugins.info()
    }
  end

  def stats do
    memory = :erlang.memory()
    {uptime, _} = :erlang.statistics(:wall_clock)
    {cpu_ms, _} = :erlang.statistics(:runtime)
    cores = System.schedulers_online()

    players =
      Registry.select(Lixi.Registry, [{{{:player, :_, :_}, :_, :_}, [], [true]}]) |> length()

    playing =
      Registry.select(Lixi.Registry, [{{{:playing, :_, :_}, :_, :_}, [], [true]}]) |> length()

    %{
      "players" => players,
      "playingPlayers" => playing,
      "uptime" => uptime,
      "memory" => %{
        "free" => memory[:processes] - memory[:processes_used],
        "used" => memory[:total] - memory[:processes] + memory[:processes_used],
        "allocated" => memory[:total],
        "reservable" => memory[:total]
      },
      "cpu" => %{
        "cores" => cores,
        "systemLoad" => :cpu_sup.avg1() / 256 / cores,
        "lavalinkLoad" => cpu_ms / max(uptime, 1) / cores
      },
      "frameStats" => nil
    }
  end
end
