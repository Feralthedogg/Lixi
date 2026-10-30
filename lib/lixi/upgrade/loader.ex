defmodule Lixi.Upgrade.Loader do
  @moduledoc false
  def prepare(modules), do: :code.prepare_loading(modules)
  def finish(prepared), do: :code.finish_loading(prepared)
end
