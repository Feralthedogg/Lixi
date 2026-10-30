# Plugins

Plugin API v1 supports source resolution and HTTP callbacks through trusted
Elixir/BEAM packages. Installation does not require rebuilding the server.

## Create and build

Run from the Lixi source directory:

```sh
mix lixi.plugin.new radio --module RadioPlugin.V1 --output plugins/radio
mix lixi.plugin.pack plugins/radio --output data/plugins/staging/radio-1.0.0
```

The template contains `plugin.json`, `lib/plugin.ex`, `config.example.json`, and
a README. See the [radio example](../examples/plugins/radio/lib/plugin.ex).
It aliases finite media resources, not indefinite live streams.

Build with the server's OTP major and Elixir major/minor. Each version uses a
separate entry namespace, such as `RadioPlugin.V1` and `RadioPlugin.V2`.
Helpers belong below the entry, such as `RadioPlugin.V1.Helper`.

```json
{
  "schema": 1,
  "apiVersion": 1,
  "name": "radio",
  "version": "1.0.0",
  "entry": "RadioPlugin.V1"
}
```

The SDK compiles in a separate VM and checks metadata against `plugin.json`.
The output contains a manifest and BEAM files with SHA-256 hashes. Existing
output directories are not overwritten. Packages contain pure BEAM modules;
`@on_load`, NIF installation, and dependency downloads are unsupported.

## Callbacks

| Callback | Input | Return |
| --- | --- | --- |
| `metadata/0` | None | `%{name: "radio", version: "1.0.0", sources: ["radio:"]}` |
| `load/2` | Identifier and JSON config map | String-key Lavalink load result |
| `request/2` | Method/path/query/body map and JSON config | `{:ok, status, body}`, status 200–599, JSON body |

Implement `load/2`, `request/2`, or both. Source prefixes require `load/2`.
A request map looks like:

```elixir
%{method: "GET", path: ["health"], query: %{}, body: %{}}
```

Use `Lixi.Sources.load_builtin/1` to resolve an allowed local or HTTP resource.
Custom results must pass Lavalink track validation, including matching encoded
and info fields. Search/playlist results are limited to 100 tracks.

Plugins do not bypass source allowlists or add codecs to the native engine.

## Install and activate

Stage reviewed packages below `LIXI_PLUGIN_ROOT`, defaulting to
`$LIXI_DATA_DIR/plugins/staging`. The API takes a bundle ID and config; it does
not upload code or download a URL.

```sh
export LIXI_PASSWORD='your-password'
export LIXI_ADMIN_TOKEN='your-separate-admin-token'

mix lixi.admin POST /plugins/packages \
  --body '{"bundle":"radio-1.0.0","config":{"tracks":{}}}'
mix lixi.admin POST /plugins/radio/activate --body '{"version":"1.0.0"}'
mix lixi.admin GET /plugins
```

The server must already have matching credentials. Direct HTTP installation is
`POST /v4/lixi/plugins/packages` with both authentication headers. Success is
201. The catalogue returns public metadata and omits config.

Bundle IDs are 1–64 ASCII characters: an initial letter/digit followed by
letters, digits, `_`, `-`, or `.`. Parent paths, symlinks, invalid hashes,
incompatible toolchains, and existing-module overwrites are rejected.

For the template, configure media aliases through `tracks`:

```json
{"tracks":{"demo":"https://media.example/demo.mp3"}}
```

The server must allow that host and HTTP source type. After activation:

```sh
curl -H "Authorization: $LIXI_PASSWORD" \
  http://127.0.0.1:2333/v4/plugins/radio/health

curl --get http://127.0.0.1:2333/v4/loadtracks \
  -H "Authorization: $LIXI_PASSWORD" \
  --data-urlencode 'identifier=radio:demo'
```

Precompiled-module installation remains available through `/v4/lixi/plugins`.
Its allowlist and startup settings are in [configuration](configuration.md#plugins).

## Switch and remove

Install a new version before selecting it:

```sh
mix lixi.admin POST /plugins/packages \
  --body '{"bundle":"radio-2.0.0","config":{"tracks":{}}}'
mix lixi.admin POST /plugins/radio/activate --body '{"version":"2.0.0"}'

# Return to a retained version.
mix lixi.admin POST /plugins/radio/activate --body '{"version":"1.0.0"}'
mix lixi.admin DELETE /plugins/radio/2.0.0
```

Running callbacks retain their original version lease. Active or leased
versions cannot be removed. Different code/config cannot overwrite an installed
name/version. Deactivation stops new selection; removal deletes the installed
registration without forcibly purging code or deleting artifact history.

## Persistence and recovery

Installed files live in `plugins/artifacts/<hash>/`; package/config and
standalone active choices live in `plugins/installed.json`. Keep them together.
The registry uses mode 0600. Clustered activation follows Raft and requires
matching packages/config on the intended providers.

Missing or altered installed artifacts fail startup. Failed activation writes
are compensated to the previous choice. Pending compensation blocks management
changes and reports `recoveryRequired`:

```sh
mix lixi.admin GET /plugins
mix lixi.admin POST /plugins/recover
```

## Limits

| Resource | Limit |
| --- | ---: |
| Build source files | 1–16; 1 MiB each |
| Package modules | 16; 4 MiB each; 8 MiB total |
| Manifest / config | 64 KiB each |
| Installed registry | 8 MiB |
| Installed versions | 128 per node; four per plugin |
| Active plugins / leases | 32 / 1,024 |
| Concurrent callbacks | Eight per node |
| Callback / metadata deadline | Five seconds by default / 500 ms |
| Source result / HTTP response | 256 KiB |

Plugins run with server privileges; hashes and deadlines are not a sandbox.
Timeouts do not undo external side effects. Mutation callbacks should use
idempotency keys. Background-worker lifecycle hooks are not part of API v1.
