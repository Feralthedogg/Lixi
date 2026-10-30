# Swapping

Swapping adds a current renderer and a ready-next native process to each enabled
Player. Both use the existing EDA Voice sender. The renderer keeps one Opus
encoder through transitions and fills partial frames from the next deck.

## Install

Requires Lixi 0.4.0 or later. Build with the deployment toolchain and stage the
package on each media node:

```sh
mix lixi.plugin.pack examples/plugins/swapping \
  --output data/plugins/staging/swapping-1.0.0
mix lixi.admin POST /plugins/packages \
  --body '{"bundle":"swapping-1.0.0","config":{}}'
mix lixi.admin POST /plugins/swapping/activate --body '{"version":"1.0.0"}'
```

See [plugins](plugins.md) for credentials and trusted-code requirements.
Enable Swapping before starting the Player's first track. Existing enabled
Players pin their plugin version until disabled or destroyed.

## Player routes

Prefix: `/v4/plugins/swapping/sessions/{sessionId}/players/{guildId}`.
All routes require the normal `Authorization` password.

| Method | Suffix | Behavior |
| --- | --- | --- |
| `PUT` | `/` | Enable or update settings; omit the trailing slash |
| `GET` | `/` | Current/next jobs, analysis, transition plan and applied settings |
| `POST` | `/next` | Prepare one next track; returns 202 |
| `DELETE` | `/next` | Cancel before transition rendering starts |
| `POST` | `/skip` | Start the ready transition early |

Enable with this body:

```json
{"enabled":true,"soundCheck":true,"autoMix":true}
```

Start the current track through the normal Lavalink Player route. Submit the
next track with `{"track":{"encoded":"..."}}` or
`{"track":{"identifier":"/allowed/next.webm"}}`. A second queued next job is
rejected. Stop the Player before disabling Swapping.

| Setting | Default | Range |
| --- | --- | --- |
| `soundCheck` | `true` | Boolean |
| `autoMix` | `true` | Boolean; false uses gapless succession |
| `targetLufs` | `-16` | -30 through -8 LUFS |
| `peakCeilingDb` | `-1` | -6 through 0 dBTP |
| `maxBoostDb` | `12` | 0 through 18 dB |
| `fadeMs` | `2500` | 0 through 12,000 ms |
| `maxTempoChange` | `0.06` | 0 through 0.12 |

Sound Check measures integrated loudness and true peak over the finite track,
then applies a constant gain. Peak and boost limits can leave a dynamic track
below the target. A linked stereo limiter protects mixed/filter output.
Silence or insufficient measurement does not trigger amplification.

AutoMix uses tempo/beat confidence and chroma-based major/minor key estimates.
Compatible confident tracks can match tempo within the configured bound and
align a 2-, 4-, or 8-beat fade. Other tracks use an equal-power crossfade, with
bounded silence trimming, or gapless playback. Tempo returns to normal after a
matched transition. Estimates are heuristic; structural song sections and
phrase/downbeat recognition are not implemented.

Changes to loudness settings affect future rendered frames. Transition settings
apply to the next preparation; an already prepared/rendered transition keeps its
plan. `settings` and `applied` expose that distinction. Up to 300 ms of previously
rendered audio can remain queued.

## Events and lifetime

Normal `TrackEndEvent`/`TrackStartEvent` change only after a successful Voice
send containing the next track. Additional events are `SwappingReadyEvent`,
`SwappingTransitionEvent`, `SwappingPrepareFailedEvent`, `SwappingRetiredEvent`,
and `SwappingResetEvent`.
Wait for retirement before deleting old media. A seek, filter/volume rebuild,
replacement, or renderer recovery invalidates the next job; re-submit it after
reset. The Voice connection and encryption ownership stay with EDA.

Playback and preparation each hold a physical worker lease. `LIXI_MAX_WORKERS`
(default 10) and `LIXI_MAX_PREPARERS` (default 10) are separate from the probe
budget. Pair reservation is atomic. Idle enabled Players reserve no workers
until playback starts; stop/destroy releases them. An enabled renderer waiting
at EOF keeps its leases for a late next track.

Analysis streams decoded PCM with a two-hour duration limit and a 60-second
ready deadline. Each source slot allows one asynchronous 64 KiB read. Queued
Opus is limited to 25 frames; the preparer retains at most 15 PCM frames.
Opening a next source or failing its preparation does not stop the current deck.

## Playlist and controls

After installation, run the [validation client](operations.md#metrics-and-validation)
with `--loop --shuffle --swapping`, or set `SWAPPING_ENABLED=true` in its private
`.env`. It downloads at most the current and next track, including repeated
entries, and retires files after the corresponding server event.

```sh
python3 -B scripts/validation/control.py --env /private/elixir-test/.env
```

Open `http://127.0.0.1:2334`. The Sound Check and AutoMix checkboxes save to
`swapping.json` beside the private `.env`. The client publishes its control
endpoint in `state/control.json`. The control server stays on loopback and
keeps the bot token and server password out of browser responses.

## Apple Music comparison

This is an independent implementation. Apple's [playback settings](https://support.apple.com/guide/music/playback-settings-musdf855a1b/mac)
describe AutoMix and Sound Check; [Sound Check](https://support.apple.com/en-au/109331)
equalizes perceived playback loudness. Static analysis of Music 1.7.0 on macOS
27.0.1 confirmed one `schk` playback gain path, `sqrt(1000 / N)` for nonzero
metadata `N`, plus loudness metadata delegation. It did not recover the metadata
estimator or AutoMix's private DSP/scoring. Lixi's -16 LUFS target, chroma model
and transition rules do not claim Apple algorithm equivalence.
