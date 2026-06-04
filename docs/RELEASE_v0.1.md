# llmos v0.1

llmos v0.1 is a release checkpoint for the first complete public demo surface:
a sub-16 KiB real-mode x86 kernel whose primary interface is a structured
line protocol for language models over COM1.

## What is included

- 29 discoverable primitives over protocol v1.
- CPU, memory, RTC, tick, allowlisted I/O, PCI scan, PCI config, PCI
  capability, BAR decode, and bounded BAR-relative read primitives.
- A Python bridge with REPL, transcript replay, and Anthropic-backed AI mode.
- 21 replayable demo transcripts plus extended CI probes for PCI capability
  chains and downstream PCI bridge traversal.
- Reproducible image checksum generation through `make image-checksums`.
- Kernel size reporting through `make size-report` and `make size-map`.

## Try These First

```sh
make
python3 demo/bridge.py script demo/transcripts/01_cold_discovery.llmos
python3 demo/bridge.py script demo/transcripts/03_denied_path.llmos
python3 demo/bridge.py script demo/transcripts/04_pci_walk.llmos
```

`01_cold_discovery` shows the introspection loop, `03_denied_path` shows
structured denial as useful control flow, and `04_pci_walk` shows the model
discovering the machine's PCI topology from inside the OS.

## Verification

Before this checkpoint, the local tree passed:

```sh
make check
make ci-check
make image-checksums
```

The release assets are `llmos.img` and `SHA256SUMS`.
