defmodule Lixi.TestPlugin.V1 do
  @behaviour Lixi.Plugin
  def metadata, do: %{name: "fixture", version: "1.0.0", sources: ["fixture:"]}

  def load("fixture:wait", config) do
    send(Process.whereis(Lixi.PluginProbe), {:plugin_waiting, self()})

    receive do
      :continue -> Lixi.Sources.load_builtin(config["uri"])
    end
  end

  def load(_, _), do: %{"loadType" => "empty", "data" => nil}
  def request(%{path: ["crash"]}, _), do: raise("private-value-must-not-leak")

  def request(%{path: ["slow"]}, _) do
    send(Process.whereis(Lixi.PluginProbe), {:slow_callback, self()})
    Process.sleep(60_000)
  end

  def request(_, _), do: {:ok, 200, %{version: "1.0.0"}}
end

defmodule Lixi.TestPlugin.V2 do
  @behaviour Lixi.Plugin
  def metadata, do: %{name: "fixture", version: "2.0.0", sources: ["fixture:"]}
  def load(_, _), do: %{"loadType" => "empty", "data" => nil}
  def request(_, _), do: {:ok, 200, %{version: "2.0.0"}}
end

defmodule Lixi.TestPlugin.SlowMetadata do
  @behaviour Lixi.Plugin
  def metadata do
    send(Process.whereis(Lixi.PluginProbe), {:slow_metadata, self()})
    Process.sleep(60_000)
  end

  def request(_, _), do: {:ok, 200, %{}}
end

defmodule Lixi.TestFailingLoader do
  def prepare(modules), do: Lixi.Upgrade.Loader.prepare(modules)
  def finish(_), do: {:error, :injected_failure}
end

defmodule Lixi.TestPlugin.PackageLegacy do
  @behaviour Lixi.Plugin
  def metadata, do: %{name: "packaged_fixture", version: "0.9.0", sources: ["packaged_fixture:"]}
  def load(_, _), do: %{"loadType" => "empty", "data" => nil}
  def request(_, _), do: {:ok, 200, %{label: "legacy"}}
end
