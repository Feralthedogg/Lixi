# Swapping

A current renderer and a ready-next native process share one Discord Voice sender.
The renderer keeps its Opus encoder across track changes. Next-track analysis and
source opening run outside the playback clock.

Build and install this directory with the [plugin SDK](../../../docs/plugins.md).
See [Swapping](../../../docs/swapping.md) for routes, settings and resource limits.
