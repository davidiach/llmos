# llmos demo guide

The repository ships with replayable transcripts under `demo/transcripts/`
and recorded outputs under `demo/recordings/`. Each transcript is a small
scenario that exercises one part of the OS surface.

Run one transcript after building:

```sh
python3 demo/bridge.py script demo/transcripts/01_cold_discovery.llmos
```

Run the smoke suite:

```sh
make smoke
```

## Demo beats

| Beat | Transcript | What it shows |
| ---- | ---------- | ------------- |
| 1 | `01_cold_discovery.llmos` | Cold discovery from `help` and `describe`, with no prior capability model. |
| 2 | `02_hardware_archaeology.llmos` | CPU, memory, RTC, IVT, and BIOS data area reads composed into a machine sketch. |
| 3 | `03_denied_path.llmos` | A denied ATA port read becomes useful boundary information rather than an ambiguous failure. |
| 4 | `04_pci_walk.llmos` | PCI bus enumeration through `pci.scan`. |
| 5 | `05_bar_windows.llmos` | BAR decoding for I/O and memory windows on discovered PCI functions. |
| 6 | `06_bar_reads.llmos` | BAR-relative I/O reads and structured denial for non-allowlisted ports. |
| 7 | `07_mem_reads.llmos` | Small memory BAR reads through the kernel's bounded MMIO primitive. |
| 8 | `08_typed_mem_reads.llmos` | Typed 8/16/32-bit MMIO reads with decoded little-endian values. |
| 9 | `09_config_reads.llmos` | Raw PCI configuration-space reads for device header fields. |
| 10 | `10_typed_config_reads.llmos` | Typed PCI config reads and alignment validation. |
| 11 | `11_capability_list.llmos` | Conventional PCI capability-list traversal with bounded malformed-chain handling. |
| 12 | `12_capability_reads.llmos` | Capability-relative reads and the structured not-found path. |
| 13 | `13_typed_memory_reads.llmos` | Typed low-memory reads from BIOS-loaded memory. |
| 14 | `14_segment_memory_reads.llmos` | Explicit real-mode segment:offset reads, including the BIOS reset vector. |
| 15 | `15_typed_segment_memory_reads.llmos` | Typed segment:offset reads and cross-segment validation. |
| 16 | `16_line_length.llmos` | Overlong requests fail without executing a truncated prefix. |
| 17 | `17_no_arg_validation.llmos` | `args=none` primitives reject unexpected arguments. |
| 18 | `18_describe_arg_validation.llmos` | Malformed `describe` calls stay distinct from unknown primitive names. |
| 19 | `19_key_validation.llmos` | Structured primitives reject unknown and duplicate argument keys. |
| 20 | `20_bdf_width_validation.llmos` | PCI BDF arguments must match the fixed-width shape emitted by discovery. |
| 21 | `21_script_exact_lines.llmos` | Script replay preserves exact request bytes, including leading spaces. |

## Reading the set

The first five beats show the intended loop: discover primitives, inspect
schemas, compose a task, and use structured errors to refine the next step.
The middle beats expand the hardware surface through PCI config space,
capabilities, BARs, I/O, and MMIO. The final beats are protocol-hardening
checks that make sure the bridge and kernel preserve exact request semantics.

The same scenarios are useful both as demos and regression fixtures: they are
small enough to read, deterministic enough for CI, and concrete enough to show
what an LLM-facing OS surface is trying to make possible.
