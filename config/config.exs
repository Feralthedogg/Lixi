import Config

config :lixi,
  port: 2333,
  ip: {127, 0, 0, 1},
  password: "youshallnotpass",
  max_players: 100,
  max_workers: 10,
  max_sessions: 100,
  max_event_buffer: 256,
  cluster_enabled: false,
  cluster_nodes: [],
  cluster_timeout: 1_000,
  plugins: [],
  plugin_modules: [Lixi.Plugins.Aliases],
  plugin_timeout: 5_000,
  data_dir: Path.expand("../data", __DIR__),
  source_roots: [],
  http_sources: false,
  player_update_interval: 5_000,
  voice_module: Lixi.Voice.EDA

config :logger, level: :info
import_config "#{config_env()}.exs"
