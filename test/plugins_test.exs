defmodule Lixi.PluginsTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  setup do
    Process.register(self(), Lixi.PluginProbe)
    old = Application.get_env(:lixi, :plugin_timeout)

    on_exit(fn ->
      Application.put_env(:lixi, :plugin_timeout, old)

      for name <- ["fixture", "aliases"] do
        Lixi.Plugins.deactivate(name)
        for version <- ["1.0.0", "2.0.0"], do: Lixi.Plugins.remove(name, version)
      end
    end)

    :ok
  end

  test "example source plugin resolves playable media and exposes a v4 HTTP extension" do
    file = fixture()
    assert {:ok, _} = Lixi.Plugins.install(Lixi.Plugins.Aliases, %{"tracks" => %{"tone" => file}})
    assert :ok = Lixi.Plugins.activate("aliases", "1.0.0")
    result = request(:get, "/v4/loadtracks?identifier=alias:tone") |> json()
    assert result["loadType"] == "track"
    assert result["data"]["info"]["identifier"] == file
    assert json(request(:get, "/v4/plugins/aliases/health"))["tracks"] == 1

    assert %{"name" => "aliases", "version" => "1.0.0"} in json(request(:get, "/v4/info"))[
             "plugins"
           ]

    assert json(request(:get, "/v4/loadtracks?identifier=alias:missing"))["loadType"] == "empty"
  end

  test "activation is atomic while an older callback keeps its immutable lease" do
    file = fixture()
    assert {:ok, _} = Lixi.Plugins.install(Lixi.TestPlugin.V1, %{"uri" => file})
    assert :ok = Lixi.Plugins.activate("fixture", "1.0.0")
    task = Task.async(fn -> Lixi.Sources.load("fixture:wait") end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:plugin_waiting, callback}, 1000
    assert {:ok, _} = Lixi.Plugins.install(Lixi.TestPlugin.V2)
    assert :ok = Lixi.Plugins.activate("fixture", "2.0.0")
    assert json(request(:get, "/v4/plugins/fixture/version"))["version"] == "2.0.0"
    assert {:error, :plugin_in_use} = Lixi.Plugins.remove("fixture", "1.0.0")
    send(callback, :continue)
    assert Task.await(task)["loadType"] == "track"
    eventually(fn -> Lixi.Plugins.remove("fixture", "1.0.0") == :ok end)
  end

  test "plugin exceptions and deadlines do not crash the node or leave a callback running" do
    assert {:ok, _} = Lixi.Plugins.install(Lixi.TestPlugin.V1)
    assert :ok = Lixi.Plugins.activate("fixture", "1.0.0")
    result = request(:get, "/v4/plugins/fixture/crash")
    assert result.status == 502
    refute result.resp_body =~ "private-value"
    Application.put_env(:lixi, :plugin_timeout, 30)
    assert {:error, :plugin_timeout} = Lixi.Plugins.request("fixture", %{path: ["slow"]})
    assert_receive {:slow_callback, callback}
    eventually(fn -> not Process.alive?(callback) end)
    assert Process.alive?(Process.whereis(Lixi.Plugins.Manager))
  end

  test "metadata callbacks are bounded and a leased version survives a manager restart" do
    assert {:error, :plugin_timeout} = Lixi.Plugins.install(Lixi.TestPlugin.SlowMetadata)
    assert_receive {:slow_metadata, callback}
    eventually(fn -> not Process.alive?(callback) end)
    {:ok, _} = Lixi.Plugins.install(Lixi.TestPlugin.V1)
    :ok = Lixi.Plugins.activate("fixture", "1.0.0")
    {:ok, lease, _} = Lixi.Plugins.Manager.checkout("fixture", "1.0.0")
    old = Process.whereis(Lixi.Plugins.Manager)
    Process.exit(old, :kill)

    eventually(fn ->
      pid = Process.whereis(Lixi.Plugins.Manager)
      is_pid(pid) and pid != old
    end)

    :ok = Lixi.Plugins.deactivate("fixture")
    assert {:error, :plugin_in_use} = Lixi.Plugins.remove("fixture", "1.0.0")
    Lixi.Plugins.Manager.checkin(lease)
    eventually(fn -> Lixi.Plugins.remove("fixture", "1.0.0") == :ok end)
  end
end
