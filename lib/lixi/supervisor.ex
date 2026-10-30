defmodule Lixi.Supervisor do
  use Supervisor

  def start_link(children), do: Supervisor.start_link(__MODULE__, children, name: __MODULE__)

  @impl true
  def init(children) do
    # Survives an Admission restart. Loss of this owner also stops every Player,
    # so a fresh table can never forget media surviving that supervision tree.
    :ets.new(Lixi.Admission, [:named_table, :public, :set])
    Supervisor.init(children, strategy: :one_for_one)
  end
end
