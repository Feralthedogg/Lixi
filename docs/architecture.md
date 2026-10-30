# Architecture

Lixi separates client control, audio computation, and Voice transmission.
Elixir owns connection state and the send boundary. Rust handles audio through
a bounded Port protocol.

## Ownership

| Component | Owns |
| --- | --- |
| HTTP/WebSocket frontend | Client connection and protocol exchange |
| Session controller | Resume policy, socket binding, Player references, and buffered events |
| Guild Player | Playback policy, media epoch, raw Opus queue, and playback clock |
| EDA Voice sender | Signaling, DAVE resource, RTP state, transport key/nonce, and UDP socket |
| SourceReader | Allowed source handle, resource version, and random reads |
| Rust worker | Decoder, DSP, resampler, and Opus encoder |
| Cluster directory | Ownership tokens, instance state, active plugins, and key fingerprints |
| Plugin manager | Installed versions, configuration, and callback leases |

The bot keeps its main Discord Gateway connection. Lixi runs EDA's Voice/DAVE
components without starting EDA's main bot Gateway.

## Media flow

```text
allowed file / versioned HTTP resource
                │
                ▼
           SourceReader
                ▲
                │ READ_AT(offset, length)
                ▼
         Rust audio worker
   decode → DSP → resample → raw Opus
                │
                ▼
          Player raw queue
                │ 20 ms deadline
                ▼
          EDA Voice sender
     DAVE → RTP → transport AEAD → UDP
                │
                ▼
             Discord
```

Rust receives source bytes instead of opening paths or URLs itself. Queues
contain raw Opus; encryption uses current Voice state at transmission.
Playback position advances after successful UDP submission.

Media epochs invalidate old output after seek or filter changes. DAVE epochs
control encryption state. Neither permits reusing a sender's transport nonce.
The media gate stays closed during DAVE prepare/execute transitions.

## Budgets

| Resource | Default or bound |
| --- | --- |
| One input read | 64 KiB |
| Raw frames and production reservations | 25 frames maximum |
| Raw buffer target | 15 frames |
| Native workers, including probes | 10 per instance |
| Plugin callbacks | Eight concurrent executions; five-second default deadline |
| Critical event outbox | 4,096 entries / 8 MiB per node |
| Disconnected-session event buffer | 256 critical events |

Output credit is cumulative: repeating a credit does not authorize extra
production. Ownership reads run outside the media clock. Critical events use
ordered acknowledged forwarding; periodic updates and stats are best effort.
Event queues are bounded memory, not durable replicas.

## Recovery

| Failure | Behavior |
| --- | --- |
| Audio worker exits | Reopen at the retained queue boundary and keep Voice connected |
| Resumable client disconnects | Retain the session until timeout and buffer critical events |
| Controller transfer is unfinished | Reconcile staged state using ownership generations |
| Metadata access or quorum is unavailable | Reject new claims and affected control queries; existing local media may continue |
| Remote owner is disconnected | Preserve ownership instead of creating a competing sender |
| Sender death is confirmed | Permit a new owner, subject to transport-key reuse checks |
| Remote termination is unconfirmed | Return unavailable and retain the Player record |

The audio worker has an OS-process crash boundary. The DAVE NIF runs inside the
BEAM VM and has a different fault boundary. Whole-VM session/media failover is
not provided.

## Cluster and updates

Raft stores metadata, not audio, Voice keys, nonce counters, or DAVE resources.
A session controller can move while the Player, Voice sender, and worker stay
on their original node. A frontend socket can also remain on its original
node; moving its controller does not make that socket disappear.

Plugins lease immutable versions. Compatible hot patches retain media PIDs and
only add declared state defaults. Changes to OTP, NIFs, Voice/crypto, cluster
internals, or the native protocol use the replacement procedure in
[operations](operations.md).
