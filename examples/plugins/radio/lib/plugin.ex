defmodule RadioPlugin.V1 do
  @behaviour Lixi.Plugin
  @impl true
  def metadata, do: %{name: "radio", version: "1.0.0", sources: ["radio:"]}

  @impl true
  def load("radio:" <> key, config) do
    case get_in(config, ["tracks", key]) do
      uri when is_binary(uri) -> Lixi.Sources.load_builtin(uri)
      _ -> %{"loadType" => "empty", "data" => nil}
    end
  end

  @impl true
  def request(%{method: "GET", path: ["health"]}, config) do
    {:ok, 200,
     %{name: "radio", version: "1.0.0", tracks: map_size(Map.get(config, "tracks", %{}))}}
  end

  def request(_, _), do: {:ok, 404, %{error: "Plugin route not found"}}
end
