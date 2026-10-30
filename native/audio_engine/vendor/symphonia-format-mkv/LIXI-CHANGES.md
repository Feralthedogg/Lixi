# Symphonia Matroska demuxer

Based on symphonia-format-mkv 0.5.5, licensed under MPL-2.0.

Lixi preserves Opus codec delay, seek preroll and signed block padding, counts dense Opus audio in 48 kHz samples, and bounds individual EBML allocations to 16 MiB. Initial probing and Opus seeks scan the finite source with bounded memory. Timestamp discontinuities beyond container precision are rejected. Other codecs retain upstream handling.

Upstream: https://github.com/pdeljanov/Symphonia/tree/v0.5.5/symphonia-format-mkv
