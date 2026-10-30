import Config

if config_env() != :test do
  cluster_names =
    System.get_env("LIXI_CLUSTER_NODES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()

  if length(cluster_names) > 31 or
       Enum.any?(cluster_names, &(byte_size(&1) > 255 or not String.contains?(&1, "@"))),
     do: raise("LIXI_CLUSTER_NODES requires at most 31 fully qualified node names")

  positive = fn name, default, maximum ->
    value = System.get_env(name, to_string(default)) |> String.to_integer()
    if value not in 1..maximum, do: raise("#{name} must be between 1 and #{maximum}")
    value
  end

  data_directory = System.get_env("LIXI_DATA_DIR", Path.expand("data")) |> Path.expand()

  {:ok, listen_ip} =
    :inet.parse_address(System.get_env("LIXI_HOST", "127.0.0.1") |> String.to_charlist())

  config :lixi,
    ip: listen_ip,
    port: String.to_integer(System.get_env("LIXI_PORT", "2333")),
    password: System.get_env("LIXI_PASSWORD", "youshallnotpass"),
    admin_token: System.get_env("LIXI_ADMIN_TOKEN"),
    cluster_enabled: cluster_names != [],
    cluster_nodes: Enum.map(cluster_names, &String.to_atom/1),
    cluster_timeout: positive.("LIXI_CLUSTER_TIMEOUT", 1_000, 10_000),
    max_players: positive.("LIXI_MAX_PLAYERS", 100, 100_000),
    max_workers: positive.("LIXI_MAX_WORKERS", 10, 100_000),
    max_probe_workers: positive.("LIXI_MAX_PROBE_WORKERS", 2, 1_000),
    max_preparers: positive.("LIXI_MAX_PREPARERS", 10, 100_000),
    max_sessions: positive.("LIXI_MAX_SESSIONS", 100, 100_000),
    data_dir: data_directory,
    upgrade_root: System.get_env("LIXI_UPGRADE_ROOT", Path.join(data_directory, "upgrades")),
    plugin_paths: System.get_env("LIXI_PLUGIN_PATHS", "") |> String.split(":", trim: true),
    plugin_root: System.get_env("LIXI_PLUGIN_ROOT", Path.join(data_directory, "plugins/staging")),
    http_hosts: System.get_env("LIXI_HTTP_HOSTS", "") |> String.split(",", trim: true),
    source_roots: System.get_env("LIXI_SOURCE_ROOTS", "") |> String.split(":", trim: true),
    http_sources: System.get_env("LIXI_HTTP_SOURCES", "false") == "true"

  if modules = System.get_env("LIXI_PLUGIN_MODULES") do
    names = String.split(modules, ",", trim: true)

    if length(names) > 32 or
         Enum.any?(
           names,
           &(byte_size(&1) > 128 or not Regex.match?(~r/^[A-Z][a-zA-Z0-9_.]*$/, &1))
         ),
       do: raise("LIXI_PLUGIN_MODULES requires at most 32 trusted module names")

    # Only the operator's bounded environment configuration can create module atoms.
    config :lixi, plugin_modules: Enum.map(names, &String.to_atom("Elixir." <> &1))
  end

  if file = System.get_env("LIXI_PLUGINS_FILE") do
    {:ok, %{type: :regular, size: size}} = File.lstat(file)
    if size > 65_536, do: raise("LIXI_PLUGINS_FILE exceeds 64 KiB")
    config :lixi, plugin_boot_file: file
  end
end
