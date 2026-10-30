# Configuration

Defaults are in [`config/config.exs`](../config/config.exs). Environment settings
are read by [`config/runtime.exs`](../config/runtime.exs) outside test mode.

## Listener and credentials

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIXI_HOST` | `127.0.0.1` | Listener IP literal |
| `LIXI_PORT` | `2333` | HTTP and WebSocket port |
| `LIXI_PASSWORD` | `youshallnotpass` | Direct `Authorization` header value |
| `LIXI_ADMIN_TOKEN` | Unset | Additional admin credential, at least 16 bytes |

An unset or short admin token disables management access. The server and admin
CLI must receive matching credentials. Changing a shell variable does not
reconfigure an already-running server.

## Media

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIXI_SOURCE_ROOTS` | Empty | Allowed absolute roots, separated by `:` |
| `LIXI_HTTP_SOURCES` | `false` | Set to `true` to enable HTTP sources |
| `LIXI_HTTP_HOSTS` | Empty | Allowed host names, separated by `,` |

Local resources must be regular files without symlink components. HTTP
resources require positive finite length, a strong ETag, and exact Range
responses. Redirects and URI user information are unsupported.

## Capacity

| Variable | Default | Accepted range |
| --- | ---: | ---: |
| `LIXI_MAX_PLAYERS` | 100 | 1–100,000 |
| `LIXI_MAX_WORKERS` | 10 | 1–100,000 |
| `LIXI_MAX_PREPARERS` | 10 | 1–100,000 |
| `LIXI_MAX_PROBE_WORKERS` | 2 | 1–1,000 |
| `LIXI_MAX_SESSIONS` | 100 | 1–100,000 |
| `LIXI_CLUSTER_TIMEOUT` | 1,000 ms | 1–10,000 ms |

[Swapping](swapping.md) uses an additional independent preparation budget.
Limits are per instance. Playback permits and probe workers use independent
budgets: ten playback slots plus two probe processes by default. A playback
permit stays with its Player through seek, filter changes and decoder recovery;
unused allocation reservations expire after 15 seconds. Metadata probes cannot
consume playback permits. Saturating the probe budget returns `worker_capacity`.
New playback placement considers both Player and playback-slot utilization and
reserves a slot atomically on the selected node.
Configuration maxima are validation bounds, not throughput guarantees.

## Cluster and storage

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIXI_DATA_DIR` | `./data` | Persistent metadata, plugins, and patch state |
| `LIXI_CLUSTER_NODES` | Empty | Comma-separated fully qualified voter names; enables clustering when non-empty |
| `LIXI_UPGRADE_ROOT` | `$LIXI_DATA_DIR/upgrades` | Hot-patch staging root |
| `RELEASE_DISTRIBUTION` | Release default | `name` for cluster nodes; `none` for standalone |
| `RELEASE_NODE` | Release default | Stable identity such as `lixi@node.example` |
| `RELEASE_COOKIE` | Release cookie | Shared distribution credential |

All members use the same fixed voter list. Up to 31 voter names and 64 total
instances are supported by the metadata catalogue. The deployment example uses
three voters and additional worker clients.

Give each node its own data directory. Do not share or erase Raft state during
replacement. Distribution needs a controlled network or
[TLS configuration](operations.md#deployment); a cookie does not encrypt traffic.

## Plugins

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIXI_PLUGIN_ROOT` | `$LIXI_DATA_DIR/plugins/staging` | Reviewed package staging directories |
| `LIXI_PLUGIN_PATHS` | Empty | Startup ebin paths, separated by `:` |
| `LIXI_PLUGIN_MODULES` | `Lixi.Plugins.Aliases` | Precompiled-module allowlist, separated by `,`; up to 32 names |
| `LIXI_PLUGINS_FILE` | Unset | Precompiled boot declarations; regular JSON file, at most 64 KiB |

The module allowlist applies to precompiled installation. Package installation
reads its entry module from a verified staged manifest.

```json
[
  {"module":"Lixi.Plugins.Aliases","config":{"tracks":{}}}
]
```

Installed package/config state is restored from the package registry and does
not require a boot-file declaration. See [plugins](plugins.md).

## Stored state

```text
data/
├── raft/                       # voting-node metadata
├── hot-upgrade.json            # committed patch journal
├── upgrade-history/            # patch and rollback code
├── upgrades/                   # staged patches
└── plugins/
    ├── staging/                # staged packages
    ├── artifacts/<hash>/       # installed package files
    └── installed.json          # package/config and standalone active choices
```

Keep registries with their referenced artifacts. `plugins/installed.json` uses
mode 0600 and may contain private configuration. Voice keys, nonce counters,
DAVE resources, and audio are not stored in Raft.

## Elixir-only settings

| Setting | Default | Purpose |
| --- | ---: | --- |
| `:max_event_buffer` | 256 | Critical events per disconnected resumable session |
| `:plugin_timeout` | 5,000 ms | Callback deadline |
| `:player_update_interval` | 5,000 ms | Player update interval |

These settings are configured in Elixir rather than through additional
environment variables. Media and queue budgets are listed in
[architecture](architecture.md#budgets).
