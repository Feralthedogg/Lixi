# radio

Elixir/BEAM plugin for Lixi plugin API v1. Edit `lib/plugin.ex` and `plugin.json` together.
Use a new module namespace for every version (for example `RadioPlugin.V1Next`).

From the Lixi server source directory:

```sh
mix lixi.plugin.pack "examples/plugins/radio" --output /existing/staging/radio-1.0.0
```

Stage that directory under the server's `LIXI_PLUGIN_ROOT`, then POST
`/v4/lixi/plugins/packages` with `{"bundle":"radio-1.0.0","config":{"tracks":{}}}`.
Activate `radio` version `1.0.0` with the management API. Source identifiers
use `radio:demo`; `GET /v4/plugins/radio/health` reports the configured track count.
Media paths and HTTP hosts must be allowed by the server's source settings.
