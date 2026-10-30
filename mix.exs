defmodule Lixi.MixProject do
  use Mix.Project

  def project do
    [
      app: :lixi,
      version: "0.4.0",
      elixir: "~> 1.20",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r/test\/(support|runtime|tmp)\//],
      releases: [lixi: [applications: [eda: :load, ra: :load]]],
      deps: deps(),
      aliases: [check: ["format --check-formatted", "compile --warnings-as-errors", "test"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets, :os_mon, :websockex],
      mod: {Lixi.Application, []}
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ra, "~> 3.2.0", runtime: false},
      {:eda,
       git: "https://github.com/qoyri/EDA.git",
       ref: "14f6abfae50420a986c22ce393524d8238d4ec9b",
       runtime: false},
      {:rustler, "~> 0.35", runtime: false}
    ]
  end
end
