defmodule Lixi.PlayerTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  test "actual audio pauses, seeks and resumes without replacing the Voice session" do
    id = session()
    track = fixture(48_000, 2000) |> track()
    path = "/v4/sessions/#{id}/players/456"

    assert request(:patch, path, %{track: %{encoded: track["encoded"]}, voice: voice()}).status ==
             200

    assert {:ok, player} = Lixi.Sessions.player(id, "456")
    eventually(fn -> Lixi.Player.snapshot(player)["state"]["position"] >= 60 end)
    connection = :sys.get_state(player).connection
    assert request(:patch, path, %{paused: true}).status == 200
    position = Lixi.Player.snapshot(player)["state"]["position"]
    Process.sleep(80)
    assert Lixi.Player.snapshot(player)["state"]["position"] == position
    assert request(:patch, path, %{position: 800}).status == 200
    assert Lixi.Player.snapshot(player)["state"]["position"] == 800
    assert request(:patch, path, %{paused: false}).status == 200
    eventually(fn -> Lixi.Player.snapshot(player)["state"]["position"] >= 840 end)
    assert :sys.get_state(player).connection == connection
    assert Process.alive?(connection)
    state = :sys.get_state(player)
    assert state.count + state.limit - state.received <= 25
    assert request(:delete, path).status == 204
  end

  test "killed audio engine recovers from the retained tail and leaves Voice connected" do
    id = session()
    track = fixture(48_000, 3000) |> track()
    path = "/v4/sessions/#{id}/players/456"

    assert request(:patch, path, %{track: %{encoded: track["encoded"]}, voice: voice()}).status ==
             200

    {:ok, player} = Lixi.Sessions.player(id, "456")
    eventually(fn -> Lixi.Player.snapshot(player)["state"]["position"] >= 60 end)
    state = :sys.get_state(player)
    original = state.worker
    connection = state.connection
    worker = :sys.get_state(original)
    {:os_pid, os_pid} = Port.info(worker.port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    eventually(fn -> :sys.get_state(player).worker != original end)
    eventually(fn -> Lixi.Player.snapshot(player)["state"]["position"] > state.position + 100 end)
    assert :sys.get_state(player).connection == connection
    assert Lixi.Player.snapshot(player)["state"]["connected"]
    assert Process.alive?(connection)
    request(:delete, path)
  end

  test "EOF and explicit stop dispatch the correct Lavalink event reasons" do
    id = session()
    track = fixture(48_000, 200) |> track()
    path = "/v4/sessions/#{id}/players/456"
    request(:patch, path, %{track: %{encoded: track["encoded"]}, voice: voice()})
    assert_receive {:lixi_event, %{type: "TrackStartEvent"}}, 1500
    assert_receive {:lixi_event, %{type: "TrackEndEvent", reason: "finished"}}, 1500
    assert json(request(:get, path))["track"] == nil
    request(:patch, path, %{track: %{encoded: track["encoded"]}, paused: true})
    request(:patch, path, %{track: %{encoded: nil}})
    assert_receive {:lixi_event, %{type: "TrackEndEvent", reason: "stopped"}}, 1000
    request(:delete, path)
  end

  test "endTime stops at the requested boundary" do
    id = session()
    track = fixture(48_000, 1000) |> track()
    path = "/v4/sessions/#{id}/players/456"
    request(:patch, path, %{track: %{encoded: track["encoded"]}, voice: voice(), endTime: 110})
    {:ok, player} = Lixi.Sessions.player(id, "456")
    eventually(fn -> :sys.get_state(player).connection != nil end)
    connection = :sys.get_state(player).connection
    assert_receive {:lixi_event, %{type: "TrackEndEvent", reason: "finished"}}, 1500
    assert :sys.get_state(connection).position == 110
    request(:delete, path)
  end
end
