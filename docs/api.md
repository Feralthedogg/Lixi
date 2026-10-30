# API

Lixi implements Lavalink v4 control paths and data shapes. Upstream references:
[REST](https://lavalink.dev/api/rest) and
[WebSocket](https://lavalink.dev/api/websocket).

## Authentication

```http
Authorization: <LIXI_PASSWORD>
```

Use the password directly, without `Bearer`. `/version`, `/health/live`, and
`/health/ready` are public. `/v4/lixi/*` additionally requires
`x-lixi-admin-token`. JSON request bodies are limited to 256 KiB.

## Routes

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/version` | Text version, such as `4.0.0+lixi.0.3.0` |
| GET | `/v4/info` | Capabilities and active plugins |
| GET | `/v4/stats` | Local instance statistics |
| GET | `/v4/loadtracks?identifier=...` | Resolve a source or plugin identifier |
| GET | `/v4/decodetrack?encodedTrack=...` | Decode one track |
| POST | `/v4/decodetracks` | Decode up to 100 tracks |
| GET | `/v4/websocket` | WebSocket upgrade |
| PATCH | `/v4/sessions/{sessionId}` | Resume policy and timeout |
| GET | `/v4/sessions/{sessionId}/players` | List Players |
| GET, PATCH, DELETE | `/v4/sessions/{sessionId}/players/{guildId}` | Inspect, update, or destroy a Player |
| GET | `/v4/routeplanner/status` | Disabled status, 204 |
| POST | `/v4/routeplanner/free/address`, `/v4/routeplanner/free/all` | Disabled error, 500 |

Tracks use Lavaplayer v1–v3 encoding, including Java modified UTF-8. Built-in
loaders resolve finite local and HTTP resources. Plugins can return validated
track, search, playlist, empty, or error load results.

## Sessions

WebSocket upgrades require `Authorization`, numeric bot `User-Id`, and a
`Client-Name` containing `/` with at most 200 bytes. Send `Session-Id` to resume.

```json
{"op":"ready","resumed":false,"sessionId":"<LIXI_SESSION_ID>"}
```

Enable resume after receiving `ready`:

```sh
curl -X PATCH "http://127.0.0.1:2333/v4/sessions/$SESSION_ID" \
  -H "Authorization: $LIXI_PASSWORD" \
  -H 'Content-Type: application/json' \
  --data '{"resuming":true,"timeout":60}'
```

Timeout is 0–3,600 seconds. Reconnect with the same bot identity and previous
Lixi session ID to retain Players and replay buffered critical events.
Without resume, socket loss removes the session and its Players.

## Player updates

Guild IDs are numeric snowflake strings. Use the session ID from the WebSocket.

```sh
curl -X PATCH "http://127.0.0.1:2333/v4/sessions/$SESSION_ID/players/$GUILD_ID" \
  -H "Authorization: $LIXI_PASSWORD" \
  -H 'Content-Type: application/json' \
  --data '{"track":{"identifier":"/absolute/path/to/music/tone.wav"},"volume":100}'
```

| Field | Purpose |
| --- | --- |
| `track.encoded`, `track.identifier` | Select a track |
| `track.userData` | Client metadata |
| `position`, `endTime` | Seek and end boundary in milliseconds |
| `volume`, `paused`, `filters` | Playback settings |
| `voice` | Discord `token`, `endpoint`, `sessionId`, and `channelId` |

Deprecated `encodedTrack` and `identifier` fields are supported. A null track
stops playback; empty filters reset filters. Omitted fields retain their
contract-specific values. `noReplace=true` keeps an existing track. A newly
selected track defaults to unpaused when `paused` is omitted.

The bot forwards Discord Voice state separately from the Lixi WebSocket
session. Media transmission waits for a ready Voice sender.

## Events, errors, and extensions

WebSocket events include `ready`, `playerUpdate`, `stats`, track start/end/error,
and Voice connection closure. Periodic updates are best effort; critical-event
buffers are bounded.

Statistics are per instance and use BEAM measurements. `frameStats` is currently
`null`. Cluster state is available through `/v4/lixi/instances`.

Missing resources return 404; unavailable owners or capacity return 503.
DELETE returns 204 only after Player termination is confirmed.

- `/v4/plugins/{name}/...`: [plugin HTTP callbacks](plugins.md).
- `/v4/lixi/*`: [management API](operations.md#management-api).
- `/health/live`: HTTP liveness.
- `/health/ready`: admission and ownership-directory readiness.
