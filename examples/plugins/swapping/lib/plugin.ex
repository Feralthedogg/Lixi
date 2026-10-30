defmodule SwappingPlugin.V1 do
  @behaviour Lixi.Plugin
  @impl true
  def metadata, do: %{name: "swapping", version: "1.0.0", sources: []}

  @impl true
  def request(request, _config), do: Lixi.Swapping.request("1.0.0", request)
end
