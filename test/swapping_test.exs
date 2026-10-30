Code.require_file("../examples/plugins/swapping/lib/plugin.ex", __DIR__)

defmodule Lixi.SwappingSlowSource do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    send(Keyword.fetch!(opts, :owner), {:next_head_waiting, self()})

    receive do
      :continue ->
        conn
        |> put_resp_header("etag", "\"slow-v1\"")
        |> put_resp_header("content-length", "1024")
        |> send_resp(200, "")
    after
      4000 -> send_resp(conn, 503, "")
    end
  end
end

defmodule Lixi.SwappingTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  setup do
    {:ok, _} = Lixi.Plugins.install(SwappingPlugin.V1)
    :ok = Lixi.Plugins.activate("swapping", "1.0.0")
    id = session()
    guild = "987"
    {:ok, player} = Lixi.Sessions.player(id, guild, true)
    base = "/v4/plugins/swapping/sessions/#{id}/players/#{guild}"

    on_exit(fn ->
      Lixi.Sessions.destroy(id, guild)
      Lixi.Plugins.deactivate("swapping")
      eventually(fn -> Lixi.Plugins.remove("swapping", "1.0.0") == :ok end)
    end)

    assert request(:put, base, %{enabled: true, autoMix: false}).status == 200
    %{id: id, guild: guild, player: player, base: base}
  end

  test "two physical workers prepare, keep one encoder and promote only on Voice send", c do
    a = fixture(48_000, 600) |> track()
    b = fixture(48_000, 800) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"

    assert request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice(), paused: true}).status ==
             200

    eventually(fn -> :sys.get_state(c.player).source_version != nil end)
    renderer = :sys.get_state(c.player).worker
    connection = :sys.get_state(c.player).connection
    port = :sys.get_state(renderer).port
    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202
    assert_receive {:lixi_event, %{type: "SwappingReadyEvent"}}, 4000
    state = :sys.get_state(c.player)
    assert is_pid(state.swapping.preparer)
    refute state.swapping.preparer == renderer

    assert Port.info(:sys.get_state(state.swapping.preparer).port, :os_pid) !=
             Port.info(port, :os_pid)

    assert Lixi.Admission.snapshot().preparers >= 1
    assert state.track == a
    assert state.position == 0
    refute_receive {:lixi_event, %{type: "TrackStartEvent"}}, 50
    assert request(:patch, path, %{paused: false}).status == 200
    assert_receive {:lixi_event, %{type: "TrackStartEvent", track: ^a}}, 1500
    assert_receive {:lixi_event, %{type: "TrackEndEvent", track: ^a, reason: "finished"}}, 2000
    assert_receive {:lixi_event, %{type: "TrackStartEvent", track: ^b}}, 2000
    assert :sys.get_state(c.player).worker == renderer
    assert :sys.get_state(renderer).port == port
    assert :sys.get_state(c.player).connection == connection
    assert_receive {:lixi_event, %{type: "SwappingRetiredEvent", track: ^a}}, 2000
    assert_receive {:lixi_event, %{type: "TrackEndEvent", track: ^b, reason: "finished"}}, 2000
    assert Lixi.Player.snapshot(c.player)["track"] == nil
  end

  test "cancel and seek fence stale prepared jobs while Voice stays connected", c do
    a = fixture(48_000, 3000) |> track()
    b = fixture(48_000, 1000) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"
    request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice()})
    assert_receive {:lixi_event, %{type: "TrackStartEvent"}}, 2000
    connection = :sys.get_state(c.player).connection
    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202

    assert_receive {:lixi_event, %{type: "SwappingReadyEvent"}},
                   3000,
                   inspect(Lixi.Swapping.status(:sys.get_state(c.player)))

    assert request(:delete, c.base <> "/next").status == 200
    assert_receive {:lixi_event, %{type: "SwappingRetiredEvent", track: ^b}}, 2000
    eventually(fn -> :sys.get_state(c.player).swapping.next == nil end)
    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202
    assert request(:patch, path, %{position: 1500}).status == 200
    eventually(fn -> Lixi.Player.snapshot(c.player)["state"]["position"] > 1520 end)
    assert :sys.get_state(c.player).connection == connection
    refute_receive {:lixi_event, %{type: "TrackStartEvent", track: ^b}}, 150
    assert :sys.get_state(c.player).swapping.next == nil
  end

  test "a missing next source leaves the current track playing and keeps its plugin lease", c do
    a = fixture(48_000, 3000) |> track()
    b = fixture(48_000, 1000) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"
    request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice()})
    assert_receive {:lixi_event, %{type: "TrackStartEvent"}}, 2000
    File.rm!(b["info"]["identifier"])
    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202
    assert_receive {:lixi_event, %{type: "SwappingPrepareFailedEvent"}}, 2000
    assert Lixi.Player.snapshot(c.player)["track"] == a
    :ok = Lixi.Plugins.deactivate("swapping")
    assert {:error, :plugin_in_use} = Lixi.Plugins.remove("swapping", "1.0.0")
    :ok = Lixi.Plugins.activate("swapping", "1.0.0")
    assert request(:put, c.base, %{soundCheck: false}).status == 200
    eventually(fn -> json(request(:get, c.base))["applied"]["soundCheck"] == false end)
  end

  test "failure of an unplayed ready source cancels only the next deck", c do
    a = fixture(48_000, 3000) |> track()
    b = fixture(48_000, 1000) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"
    request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice(), paused: true})
    eventually(fn -> :sys.get_state(c.player).source_version != nil end)
    renderer = :sys.get_state(c.player).worker
    request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}})
    assert_receive {:lixi_event, %{type: "SwappingReadyEvent"}}, 2000
    source = :sys.get_state(renderer).slots[1].pid
    Process.exit(source, :kill)
    assert_receive {:lixi_event, %{type: "SwappingPrepareFailedEvent"}}, 2000
    assert_receive {:lixi_event, %{type: "SwappingRetiredEvent", track: ^b}}, 2000
    assert :sys.get_state(c.player).worker == renderer
    assert Lixi.Player.snapshot(c.player)["track"] == a
    request(:patch, path, %{paused: false})
    eventually(fn -> Lixi.Player.snapshot(c.player)["state"]["position"] > 40 end)
  end

  test "late next preparation after EOF restores playing metrics", c do
    a = fixture(48_000, 200) |> track()
    b = fixture(48_000, 600) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"
    request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice(), endTime: 110})
    assert_receive {:lixi_event, %{type: "TrackEndEvent", track: ^a}}, 2000
    assert Lixi.Player.snapshot(c.player)["state"]["position"] == 110
    assert Registry.lookup(Lixi.Registry, {:playing, c.id, c.guild}) == []
    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202
    assert_receive {:lixi_event, %{type: "TrackStartEvent", track: ^b}}, 2000
    assert Registry.lookup(Lixi.Registry, {:playing, c.id, c.guild}) == [{c.player, nil}]
  end

  test "slow next source initialization never blocks the clock and stop/disable collects its worker",
       c do
    old_sources = Application.get_env(:lixi, :http_sources)
    old_hosts = Application.get_env(:lixi, :http_hosts)
    Application.put_env(:lixi, :http_sources, true)
    Application.put_env(:lixi, :http_hosts, ["127.0.0.1"])

    on_exit(fn ->
      Application.put_env(:lixi, :http_sources, old_sources)
      Application.put_env(:lixi, :http_hosts, old_hosts)
    end)

    a = fixture(48_000, 3000) |> track()
    path = "/v4/sessions/#{c.id}/players/#{c.guild}"
    request(:patch, path, %{track: %{encoded: a["encoded"]}, voice: voice()})
    assert_receive {:lixi_event, %{type: "TrackStartEvent"}}, 2000
    connection = :sys.get_state(c.player).connection

    server =
      start_supervised!(
        {Bandit, plug: {Lixi.SwappingSlowSource, owner: self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    uri = "http://127.0.0.1:#{port}/next.wav"

    b =
      Lixi.Track.new(
        Map.merge(a["info"], %{"identifier" => uri, "uri" => uri, "sourceName" => "http"}),
        "wav"
      )

    assert request(:post, c.base <> "/next", %{track: %{encoded: b["encoded"]}}).status == 202
    assert_receive {:next_head_waiting, request_pid}, 1500
    before = Lixi.Player.snapshot(c.player)["state"]["position"]
    Process.sleep(100)
    assert Lixi.Player.snapshot(c.player)["state"]["position"] > before
    assert :sys.get_state(c.player).connection == connection
    assert request(:delete, c.base <> "/next").status == 200
    assert request(:patch, path, %{track: %{encoded: nil}}).status == 200
    assert request(:put, c.base, %{enabled: false}).status == 200
    send(request_pid, :continue)
    eventually(fn -> Lixi.Admission.active() == 0 end, 300)
    assert :sys.get_state(c.player).swapping == nil

    # A successful result already in flight also has a collector after disable.
    assert {:ok, late} =
             Lixi.Audio.Worker.start(c.player, a["info"]["identifier"], 77,
               purpose: :prepare,
               mode: "prepare",
               swapping: %{}
             )

    monitor = Process.monitor(late)
    send(c.player, {make_ref(), {:ok, late}})
    assert_receive {:DOWN, ^monitor, :process, ^late, _}, 1500
    eventually(fn -> Lixi.Admission.active() == 0 end)
  end

  test "crossfade fills partial track boundaries through one continuous encoder" do
    a = fixture(48_000, 610)
    b = fixture(48_000, 610)

    {:ok, settings} =
      Lixi.Swapping.settings(%{"soundCheck" => false, "autoMix" => true, "fadeMs" => 200})

    assert {:ok, renderer} = Lixi.Audio.Worker.start(self(), a, 81, swapping: settings, tag: 11)

    assert {:ok, preparer} =
             Lixi.Audio.Worker.start(self(), b, 82,
               purpose: :prepare,
               swapping: settings,
               mode: "prepare",
               tag: 12
             )

    on_exit(fn ->
      Lixi.Audio.Worker.stop(renderer)
      Lixi.Audio.Worker.stop(preparer)
    end)

    assert_receive {:audio, ^renderer, 81, {:ready, _}}, 2000
    assert_receive {:audio, ^preparer, 82, {:ready, metadata}}, 2000
    Lixi.Audio.Worker.next(renderer, b, 12, metadata["analysis"], [])

    assert_receive {:audio, ^renderer, 81, {:swapping, %{"type" => "nextReady", "plan" => plan}}},
                   2000

    assert plan["mode"] == "crossfade"
    Lixi.Audio.Worker.grant(renderer, 25)
    frames = collect_transition(renderer, [], nil)
    assert length(frames) == 51
    assert Enum.sum(Enum.map(frames, & &1.valid_samples)) == 48_960
    assert List.last(frames).tag == 12
    assert List.last(frames).position == 610
  end

  defp collect_transition(worker, frames, finish) do
    if finish != nil and length(frames) >= finish do
      Enum.reverse(frames)
    else
      receive do
        {:audio, ^worker, 81, {:frame, frame}} ->
          count = length(frames) + 1
          if rem(count, 10) == 0, do: Lixi.Audio.Worker.grant(worker, count + 25)
          collect_transition(worker, [frame | frames], finish)

        {:audio, ^worker, 81,
         {:swapping, %{"type" => "ended", "tag" => 12, "afterFrame" => ordinal}}} ->
          collect_transition(worker, frames, ordinal)

        {:audio, ^worker, 81, {:swapping, _}} ->
          collect_transition(worker, frames, finish)

        {:audio, ^worker, 81, {:error, reason}} ->
          flunk("Transition failed: #{inspect(reason)}")
      after
        3000 -> flunk("Transition did not finish")
      end
    end
  end
end
