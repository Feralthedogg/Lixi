defmodule Lixi.MetricsTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  setup context do
    if context[:supervisor_crash] do
      :ok = Application.stop(:lixi)
      {:ok, _} = Application.ensure_all_started(:lixi)

      on_exit(fn ->
        Application.stop(:lixi)
        {:ok, _} = Application.ensure_all_started(:lixi)
      end)
    end

    :ok
  end

  test "OS accounting parses multi-day CPU time and ignores PID reuse in deltas" do
    alias Lixi.Metrics.Process, as: OS
    before = OS.parse("123 100 01:02.50 Fri Oct 30 23:00:00 2026\n")
    after_sample = OS.parse("123 120 1-01:02:03 Fri Oct 30 23:00:00 2026\n")
    assert after_sample[123].rss == 120 * 1024
    assert OS.cpu_delta(after_sample, before) == 90_123_000 - 62_500
    reused = OS.parse("123 120 00:00.20 Fri Oct 30 23:01:00 2026\n")
    assert OS.cpu_delta(reused, before) == 0
  end

  test "Linux process samples use kernel ticks, page size and process start identity" do
    fields =
      Enum.map(3..24, fn
        3 -> "S"
        14 -> "125"
        15 -> "25"
        22 -> "12345"
        24 -> "32"
        _ -> "0"
      end)

    text = "123 (lixi ) worker) " <> Enum.join(fields, " ")

    assert {:ok, %{cpu_ms: 1500, identity: "12345", rss: 131_072}} =
             Lixi.Metrics.Process.parse_proc(text, 100, 4096)

    assert {:error, :invalid_stat} = Lixi.Metrics.Process.parse_proc("truncated", 100, 4096)
  end

  @tag supervisor_crash: true
  test "native RSS is included and delivered frames appear in websocket and admin metrics" do
    file = fixture(48_000, 3000)
    id = session()
    {:ok, player} = Lixi.Sessions.player(id, "metrics", true)
    on_exit(fn -> Lixi.Sessions.destroy(id, "metrics") end)
    {:ok, patch} = Lixi.Player.validate(%{"track" => %{"identifier" => file}, "voice" => voice()})
    assert {:ok, _} = Lixi.Player.update(player, patch, false)
    eventually(fn -> :sys.get_state(player).position >= 80 end)
    send(Lixi.Metrics, :sample)
    eventually(fn -> Lixi.Metrics.snapshot().nativeProcesses == 1 end)
    old = Process.whereis(Lixi.Metrics)
    Process.exit(old, :kill)

    eventually(fn ->
      Process.whereis(Lixi.Metrics) != nil and Process.whereis(Lixi.Metrics) != old
    end)

    assert Process.alive?(player)
    eventually(fn -> :sys.get_state(player).position >= 180 end)
    send(Lixi.Metrics, :sample)
    eventually(fn -> Lixi.Metrics.snapshot().frames.sent >= 4 end)
    metrics = Lixi.Metrics.snapshot()
    assert metrics.nativeRss > 0
    assert metrics.frames.sent >= 4
    assert metrics.processSamplesComplete
    assert Lixi.Info.stats()["frameStats"] == nil
    assert Lixi.Info.stats(:websocket)["frameStats"]["sent"] >= 4
    memory = Lixi.Info.stats()["memory"]
    assert memory["used"] >= metrics.nativeRss
    assert memory["used"] + memory["free"] == memory["allocated"]
  end
end
