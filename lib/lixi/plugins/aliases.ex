defmodule Lixi.Plugins.Aliases do
  @behaviour Lixi.Plugin
  @impl true
  def metadata, do: %{name: "aliases", version: "1.0.0", sources: ["alias:"]}
  @impl true
  def load("alias:" <> key, config) do
    case get_in(config, ["tracks", key]) do
      value when is_binary(value) -> Lixi.Sources.load_builtin(value)
      _ -> %{"loadType" => "empty", "data" => nil}
    end
  end

  @impl true
  def request(%{method: "GET", path: ["health"]}, config),
    do:
      {:ok, 200,
       %{name: "aliases", version: "1.0.0", tracks: map_size(Map.get(config, "tracks", %{}))}}

  def request(_, _), do: {:ok, 404, %{message: "Plugin route not found"}}
end
