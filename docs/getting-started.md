# Getting started

## Requirements

- Elixir 1.20 and Erlang/OTP 29.
- Rust 1.88 or later.
- C/C++ compiler, CMake, and libclang.
- A bot with Lavalink v4 support.

Build the release, DAVE NIF, and audio executable for the target OS and
architecture. Local verification used macOS arm64.

## Build and run

```sh
mix deps.get
mix lixi.native

export LIXI_PASSWORD='change-this-password'
export LIXI_ADMIN_TOKEN='a-separate-admin-token-at-least-16-bytes'
export LIXI_SOURCE_ROOTS='/absolute/path/to/music'
mix run --no-halt
```

The default listener is `127.0.0.1:2333`. Use `LIXI_HOST` and `LIXI_PORT` to
change it.

```sh
curl http://127.0.0.1:2333/version
curl http://127.0.0.1:2333/health/ready
curl -H "Authorization: $LIXI_PASSWORD" http://127.0.0.1:2333/v4/info
```

Readiness returns 503 during drain or unavailable metadata access. The HTTP
password is the direct `Authorization` value, without a `Bearer` prefix.

## Load media

Local files must be non-empty WAV PCM or MP3 files below an allowed root.
Symlink paths are rejected.

```sh
curl --get http://127.0.0.1:2333/v4/loadtracks \
  -H "Authorization: $LIXI_PASSWORD" \
  --data-urlencode 'identifier=/absolute/path/to/music/tone.wav'
```

For HTTP sources, set these before starting the server:

```sh
export LIXI_HTTP_SOURCES=true
export LIXI_HTTP_HOSTS='media.example'
```

HTTP resources require finite length, a strong ETag, and correct Range
responses. Redirects and whole-resource download fallback are unsupported.

## Connect the bot

Set the bot's Lavalink host, port, and password. Its WebSocket upgrade to
`/v4/websocket` must include:

```http
Authorization: <LIXI_PASSWORD>
User-Id: <BOT_USER_ID>
Client-Name: your-client/1.0
```

Use the `sessionId` from the `ready` event in Player routes. The bot forwards
Discord's Voice `token`, `endpoint`, `sessionId`, and `channelId` in Player
updates. Lixi does not need a bot token or the bot's main Gateway connection.

For resume, PATCH the Lixi session with `resuming: true` and a timeout. Send
`Session-Id` on the next WebSocket connection with the same bot identity.
The Lixi session ID and Discord Voice session ID are different values.

## Production release

After building native components for the target platform:

```sh
MIX_ENV=prod mix release
_build/prod/rel/lixi/bin/lixi start
```

Set runtime environment variables on the release process. Use a persistent,
separate `LIXI_DATA_DIR` for each instance. Standalone releases can use
`RELEASE_DISTRIBUTION=none`; cluster setup is covered in
[operations](operations.md).

See [configuration](configuration.md), [API](api.md), and [plugins](plugins.md)
for the remaining settings and interfaces.
