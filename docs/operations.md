# Operations

## Management API

All `/v4/lixi/*` routes require `Authorization: <LIXI_PASSWORD>` and
`x-lixi-admin-token: <LIXI_ADMIN_TOKEN>`. The admin token must be at least
16 bytes. Use an instance-specific URL for local maintenance.

| Method | Route below `/v4/lixi` | Purpose |
| --- | --- | --- |
| GET | `/status` | Local counters, stop predicate, version, and upgrade recovery state |
| GET | `/instances` | Node status, capacity, versions, and plugins |
| POST | `/drain`, `/resume` | Stop or resume new session/Player admission |
| POST | `/sessions/{id}/move` | Transfer a controller to `target` |
| GET | `/plugins` | Active/installed versions and recovery state |
| POST | `/plugins` | Install an allowlisted precompiled module |
| POST | `/plugins/packages` | Install a staged package with `bundle` and `config` |
| POST | `/plugins/{name}/activate` | Select `version` |
| POST | `/plugins/{name}/deactivate` | Stop new plugin selection |
| DELETE | `/plugins/{name}/{version}` | Remove inactive, unleased registration |
| POST | `/plugins/recover` | Retry activation compensation |
| POST | `/upgrade` | Apply a staged compatible BEAM `bundle` |
| POST | `/upgrade/rollback` | Apply retained previous code |
| POST | `/upgrade/recover` | Retry upgrade recovery |

```sh
export LIXI_PASSWORD='your-password'
export LIXI_ADMIN_TOKEN='your-separate-admin-token'

mix lixi.admin GET /status --url http://127.0.0.1:2333
```

Use `--body` or `--body-file` for JSON. The CLI reads credentials from its own
environment and does not start a server. Releases can use HTTP directly or
local RPC, such as `bin/lixi rpc 'Lixi.Lifecycle.status()'`.

## Drain and replace

```sh
mix lixi.admin POST /drain --url http://127.0.0.1:2333
mix lixi.admin GET /status --url http://127.0.0.1:2333
```

Drain blocks new sessions and Player allocation while existing control and
media continue. Readiness becomes 503; liveness can remain 200.

`safe_to_stop` requires draining mode and zero local sessions, Players, Voice
senders, workers, callbacks, and pending critical events. Paused and ended
Players remain alive until deleted, so drain has no fixed completion time.

```sh
mix lixi.admin POST /sessions/SESSION_ID/move \
  --body '{"target":"lixi@node.example"}'
```

A controller move preserves media processes on their original node. It also
preserves any frontend socket on its original node. Those sockets are not
separately counted by `safe_to_stop` after the controller moves: reconnect/resume
or close them before removing that frontend.

Replace the target-native release after its required state and connections
have drained. Use `/resume` to reopen admission.

## Compatible hot patches

Patches require the same Elixir/OTP, dependencies, EDA NIF, and native protocol.
Allowed modules are `Lixi.Router`, `Lixi.Info`, `Lixi.Filters`, `Lixi.Sources`,
`Lixi.Player`, and `Lixi.Sessions`. Existing API/message and state semantics must
remain compatible.

Build the candidate separately. Use the logical version from admin `/status`
as `--from`, not the protocol-prefixed `/version` string.

```sh
MIX_ENV=prod mix lixi.bundle --from 0.3.0 --to 0.3.1 \
  --modules Lixi.Player,Lixi.Info --output /existing/staging/patch-001
```

`--defaults defaults.json` can add declared fields to Player or Sessions:

```json
{"Lixi.Player":{"upgrade_feature_flag":false}}
```

Keys must use `upgrade_` and exist in the candidate BEAM atom table. Existing
fields and values are retained. State replacement does not rewind media epochs,
playback position, or crypto counters.

Stage the directory under `LIXI_UPGRADE_ROOT`, then apply it per instance:

```sh
mix lixi.admin POST /upgrade --body '{"bundle":"patch-001"}'
mix lixi.admin GET /status
mix lixi.admin POST /upgrade/rollback
```

Code loads atomically without replacing media PIDs. Old code still in use
causes rejection instead of forced purge. Rollback can leave additive fields
for the previous code to ignore.

Keep `hot-upgrade.json` with `upgrade-history/` for startup replay and rollback.
A storage-recovery failure keeps the instance drained and blocks `/resume`.
Correct storage and call `/upgrade/recover`.

| Limit | Value |
| --- | ---: |
| Modules per bundle | Six |
| BEAM payload | 4 MiB per module; 8 MiB total |
| Manifest | 64 KiB |
| Added defaults per stateful module | 32 per bundle; 256 cumulative |
| Journal entries | 32 |

Replace the base release before exhausting the journal. Reset a patch chain
only after drain/stop while retaining its history. Preserve `raft/` rather than
emptying the whole volume. OTP, NIF, Voice/crypto, cluster-internal, and native
protocol changes use release replacement, not this patch path.

## Horizontal scaling

Use the same fixed voter list and cookie on all nodes. The deployment example
uses three voters and additional workers outside the voter list. Each node
needs a stable identity, separate persistent data, matching media paths or
allowlists, and compatible code. Install matching plugins on intended providers.

New Players use accepting capacity. Existing Voice resources are not
rebalanced. Any HTTP frontend can route control or resume to the owner;
`/v4/stats` remains local.

Loss of connectivity does not prove a sender stopped. Raft retains uncertain
ownership, and metadata-dependent requests can return unavailable while local
media continues. A new sender requires confirmed owner death and transport-key
reuse checks. Unconfirmed remote DELETE retains the Player record.

Stable node names are needed to confirm old PIDs after reconnection. Replacing
a lost node under a new name does not reclaim uncertain ownership. Dynamic voter
membership and automatic whole-VM session/media failover are unsupported.

## Deployment

Cluster releases use `RELEASE_DISTRIBUTION=name`, a stable `RELEASE_NODE`, and a
shared `RELEASE_COOKIE`. Keep distribution private or configure
[OTP TLS distribution](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html)
with peer verification. A cookie does not encrypt traffic.

The [Dockerfile](../deploy/Dockerfile) consumes a release built for the target
Linux architecture:

```sh
docker build -f deploy/Dockerfile -t your-registry/lixi:0.3.0 _build/prod/rel/lixi
```

The [Kubernetes example](../deploy/kubernetes.yaml) includes three voters, two
workers, per-node PVCs, parallel startup, readiness probes, `OnDelete` updates,
and a distribution NetworkPolicy. Replace image references and create a
`lixi-runtime` Secret with `RELEASE_COOKIE`, `LIXI_PASSWORD`, and
`LIXI_ADMIN_TOKEN`.

```sh
kubectl apply -f deploy/kubernetes.yaml
kubectl scale statefulset/lixi-worker --replicas=5
```

Check the highest worker ordinal before scaling in. preStop only requests drain;
it does not prevent forced termination. PDBs do not protect direct deletion or
every rollout. Confirm state and sockets have drained before removal.
