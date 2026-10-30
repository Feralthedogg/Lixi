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

  def stats(context \\ :rest) do
    memory = :erlang.memory()
    {uptime, _} = :erlang.statistics(:wall_clock)
    metrics = Lixi.Metrics.snapshot()
    native_rss = metrics.nativeRss
    cores = metrics.cores

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
        "used" => memory[:total] - memory[:processes] + memory[:processes_used] + native_rss,
        "allocated" => memory[:total] + native_rss,
        "reservable" => memory[:total] + native_rss
      },
      "cpu" => %{
        "cores" => cores,
        "systemLoad" => metrics.systemLoad,
        "lavalinkLoad" => metrics.cpu
      },
      "frameStats" =>
        if(context == :websocket and players > 0,
          do: Map.new([:sent, :nulled, :deficit], &{Atom.to_string(&1), metrics.frames[&1]}),
          else: nil
        )
    }
  end
end
