# llmos

[![build](https://github.com/davidiach/llmos/actions/workflows/build.yml/badge.svg)](https://github.com/davidiach/llmos/actions/workflows/build.yml)

*An operating system whose primary user is a language model.*

Operating systems have always been designed for humans to drive. Shells,
prompts, flags, man pages, ioctls — all of it assumes a person on the other
end with context, memory, and a tolerance for implicit behaviour. Language
models are now fluent enough to be that driver, but they are a different
kind of user: they are good at composition over explicit primitives, they
hold no session state the system can hold for them, they benefit from
structured responses and discoverable capability surfaces, and they treat
errors as signal rather than failure.

So: what does an OS look like when its primary user is an LLM?

llmos is one attempt at an answer. It is a ~4 KB real-mode x86 kernel
whose entire interaction surface is a line-oriented text protocol over
COM1. There is no keyboard reader and no human prompt. Every capability
is a single primitive with a typed request and a single-line response.
The model bootstraps its understanding of the machine from the inside —
`help` lists primitives, `describe NAME` returns a schema, and from there
it composes.

```
# llmos v0.1 proto=1 primitives=29
> help
< ok primitives=help,describe,cpu.vendor,cpu.features,mem.query,mem.read,mem.read8,mem.read16,mem.read32,mem.read.seg,mem.read.seg8,mem.read.seg16,mem.read.seg32,rtc.now,ticks.since_boot,io.in,pci.scan,pci.config.read,pci.config.read8,pci.config.read16,pci.config.read32,pci.cap.list,pci.cap.read,pci.bars,pci.bar.read,pci.mem.read,pci.mem.read8,pci.mem.read16,pci.mem.read32
> cpu.vendor
< ok vendor=GenuineIntel family=6 model=6 stepping=3
> mem.read addr=7c00 len=16
< ok addr=7c00 len=16 data=fa31c08ed88ec08ed0bc007cfbfc8816
> io.in port=1f0
< err code=denied detail="port not in allowlist"
```

## Design commitments

**One input channel.** COM1 only. The kernel has no keyboard driver. This
is a commitment, not an omission — a human-driven TTY would be a different
OS.

**One transaction per primitive.** Every request produces exactly one
response line. The model can safely pair sent with received. No streaming,
no interleaved events, no framing beyond `\n`.

**Structured over prose.** Responses are `ok key=value ...` or
`err code=X detail="..."`. The code vocabulary is small
(`unknown_cmd`, `bad_arg`, `out_of_range`, `denied`, `unavailable`,
`timeout`) so the model can branch on errors instead of parsing them.

**Discoverable surface.** `help` returns the primitive list.
`describe NAME` returns the schema of one primitive — args it accepts,
fields it returns, and for `io.in` the full port allowlist. The model
reads the system's self-description from inside the system.

**Errors as interface.** `io.in` to a non-allowlisted port denies
cleanly. The denial text includes enough for the model to course-correct —
ask `describe io.in`, get the allowlist, pick a legal alternative.

**Human-observable.** Every request and response mirrors to VGA text mode
so the audience watches the same transcript the model sees. Launch with
`make run-gui` to see the mirror in QEMU's window.

See `docs/PROTOCOL.md` for the full wire spec.

## Primitives (v0.1)

| Command            | Args                        | Returns                                         |
| ------------------ | --------------------------- | ----------------------------------------------- |
| `help`             | none                        | `primitives=CSV`                                |
| `describe`         | `NAME`                      | schema line for that primitive                  |
| `cpu.vendor`       | none                        | `vendor=S family=N model=N stepping=N`          |
| `cpu.features`     | none                        | `features=CSV` (CPUID leaf 1 EDX, decoded)      |
| `mem.query`        | none                        | `conv_kb=N ext_kb=N ext_blocks_64k=N`           |
| `mem.read`         | `addr=H(1-4) len=N(1-256)`  | `addr=H len=N data=HEX`                         |
| `mem.read8`        | `addr=H(1-4)`               | `addr=H width=8 value=HH`                       |
| `mem.read16`       | `addr=H(1-4,aligned)`       | `addr=H width=16 value=HHHH`                    |
| `mem.read32`       | `addr=H(1-4,aligned)`       | `addr=H width=32 value=HHHHHHHH`                |
| `mem.read.seg`     | `seg=H offset=H len=N(1-256)` | `seg=H offset=H len=N data=HEX`               |
| `mem.read.seg8`    | `seg=H offset=H`            | `seg=H offset=H width=8 value=HH`               |
| `mem.read.seg16`   | `seg=H offset=H(aligned)`   | `seg=H offset=H width=16 value=HHHH`            |
| `mem.read.seg32`   | `seg=H offset=H(aligned)`   | `seg=H offset=H width=32 value=HHHHHHHH`        |
| `rtc.now`          | none                        | `iso=YYYY-MM-DDTHH:MM:SS`                       |
| `ticks.since_boot` | none                        | `ms=N`                                          |
| `io.in`            | `port=H`                    | `port=H value=H` or `err code=denied`           |
| `pci.scan`         | none                        | `devices=B.D.F:VVVV:DDDD:CC[,...]` (bus 0 + bridges) |
| `pci.config.read`  | `bdf=BB.DD.F offset=H len=N(1-16)` | `bdf=BB.DD.F offset=H len=N data=HEX` |
| `pci.config.read8` | `bdf=BB.DD.F offset=H`      | `bdf=BB.DD.F offset=H width=8 value=HH`         |
| `pci.config.read16` | `bdf=BB.DD.F offset=H(aligned)` | `bdf=BB.DD.F offset=H width=16 value=HHHH` |
| `pci.config.read32` | `bdf=BB.DD.F offset=H(aligned)` | `bdf=BB.DD.F offset=H width=32 value=HHHHHHHH` |
| `pci.cap.list`     | `bdf=BB.DD.F`               | `bdf=BB.DD.F caps=OFF:ID[,..] truncated=N malformed=N` |
| `pci.cap.read`     | `bdf=BB.DD.F cap=H offset=H len=N(1-16)` | `bdf=BB.DD.F cap=H id=H offset=H len=N data=HEX` |
| `pci.bars`         | `bdf=BB.DD.F`               | `bdf=BB.DD.F bars=I:KIND[:BASE[:p\|n]],...`     |
| `pci.bar.read`     | `bdf=BB.DD.F bar=N offset=H len=N(1-16)` | `bdf=BB.DD.F bar=N kind=io port=H offset=H len=N data=HEX` |
| `pci.mem.read`     | `bdf=BB.DD.F bar=N offset=H len=N(1-16)` | `bdf=BB.DD.F bar=N kind=m32\|m64\|mlt1 addr=H offset=H len=N data=HEX` |
| `pci.mem.read8`    | `bdf=BB.DD.F bar=N offset=H` | `bdf=BB.DD.F bar=N kind=m32\|m64\|mlt1 addr=H offset=H width=8 value=HH` |
| `pci.mem.read16`   | `bdf=BB.DD.F bar=N offset=H(aligned)` | `bdf=BB.DD.F bar=N kind=m32\|m64\|mlt1 addr=H offset=H width=16 value=HHHH` |
| `pci.mem.read32`   | `bdf=BB.DD.F bar=N offset=H(aligned)` | `bdf=BB.DD.F bar=N kind=m32\|m64\|mlt1 addr=H offset=H width=32 value=HHHHHHHH` |

`mem.read` exposes low memory as bounded segment-0 byte strings. Its typed
siblings, `mem.read8`, `mem.read16`, and `mem.read32`, return a decoded
little-endian `value=` field from the same address space. The 16- and
32-bit forms require natural alignment; all segment-0 memory reads stay
within offset `ffff`.

`mem.read.seg` is the explicit real-mode form: callers provide `seg` and
`offset`, and the kernel reads through that segment register without crossing
past offset `ffff`. This keeps the byte-count cap and read-only discipline,
while letting a model inspect places like BIOS ROM at `f000:fff0`.
Its typed siblings, `mem.read.seg8`, `mem.read.seg16`, and
`mem.read.seg32`, keep the same segment:offset boundary but return
little-endian `value=` fields and structured alignment errors.

`io.in`'s allowlist is introspectable: `describe io.in` includes the full
list. At the moment it covers the PIC (0x20, 0x21), PIT (0x40, 0x43),
keyboard controller (0x60, 0x61, 0x64), CMOS (0x70, 0x71), and COM1
itself (0x3F8–0x3FF).

`pci.scan` walks bus 0 via the legacy 0xCF8/0xCFC config mechanism and
emits one record per populated function: bus.device.function, vendor id,
device id, and the PCI base class byte. When it encounters a PCI-to-PCI
bridge (header type 0x01), it enqueues the bridge's secondary bus and
keeps walking - so the response is the entire reachable tree, not just
bus 0. QEMU's default chipset has no bridges on bus 0, so the output is
flat there; add `-device pci-bridge,...` and the scan follows into bus 1.

`pci.config.read` is the raw config-space lens behind the higher-level PCI
summaries. It takes a `BB.DD.F` tuple plus a bounded byte offset and length,
then returns address-order bytes from conventional 256-byte PCI config space.
Absent functions return `unavailable`; reads that would cross past `0xff`
return `out_of_range`.

`pci.config.read8`, `pci.config.read16`, and `pci.config.read32` are typed
config-space siblings. They keep the same BDF plus offset shape, but return
a decoded little-endian `value=` field. The 16- and 32-bit forms require
natural alignment.

`pci.cap.list` follows the conventional PCI capability linked list when a
function advertises one. It returns `caps=OFF:ID,...`, where `OFF` is the
config-space offset and `ID` is the capability id byte, plus `truncated` and
`malformed` flags so odd device chains remain structured instead of hanging
the protocol.

`pci.cap.read` takes one of those `OFF` values back as `cap=H`, checks that
it is still present in the linked list, then reads a small byte range
relative to that capability. It is still just config-space reads underneath,
but the address shape is capability-relative and list-verified.

`pci.bars` takes one of those `BB.DD.F` tuples back and decodes the
function's Base Address Registers. Each record is `I:KIND[:BASE[:p|n]]`
where `I` is the BAR index, `KIND` is one of `none`, `io`, `m32`, `m64`,
`m64trunc`, `mlt1` (legacy <1 MB), or `rsv` (reserved encoding), `BASE`
is the base address in lowercase hex (8 digits for 32-bit kinds, 16 for
`m64`), and the `:p`/`:n` suffix marks memory BARs as prefetchable or not.
A 64-bit
BAR consumes the next slot, which is then omitted from the list. Type-0
headers report six slots; type-1 (PCI-to-PCI bridge) headers report two;
other header types return an empty `bars=`. An unpopulated function
yields `err code=unavailable`; a malformed BDF, including trailing junk
after the function digit, yields `err code=bad_arg`.

`pci.bar.read` is the first BAR-bound register read primitive. It takes the
same `BB.DD.F` tuple, a BAR slot number, a small offset (`0x00`-`0xff`),
and a byte count (`1`-`16`). In v0.1 it reads only I/O-space BARs using
8-bit port reads and returns the bytes as `data=HEX`; memory BARs return
`err code=denied`. That keeps the primitive useful for devices like the
PIIX3 IDE bus-master window while avoiding arbitrary port reads and high
MMIO addresses that real mode cannot directly dereference.

`pci.mem.read` is the memory-space sibling. It uses a flat `FS` segment
cache (set up through a tiny unreal-mode transition) to read small byte
ranges from memory BARs whose physical base fits in 32 bits. I/O BARs
return `err code=denied`, empty BARs return `unavailable`, and 64-bit
BARs with a non-zero high dword are rejected as out of range.

`pci.mem.read8`, `pci.mem.read16`, and `pci.mem.read32` are typed MMIO
siblings for register probing. They keep the same `bdf`/`bar`/`offset`
addressing discipline, but return `width=N value=HEX` so a model can work
with little-endian register values without manually decoding byte strings.
The 16- and 32-bit forms require natural alignment.

## Running it

### Requirements

- `nasm`
- `qemu-system-i386`
- `make`, `dd`
- `python3` (for the bridge)
- `pip install anthropic` (only if you want Claude to drive)

### Build

```
make               # build/llmos.img
make run           # run in QEMU, COM1 on stdio, VGA suppressed
make run-gui       # run in QEMU with the VGA window visible
make debug         # paused at start, gdb stub on :1234
```

### Drive it yourself (REPL)

```
python3 demo/bridge.py repl
> help
< ok primitives=help,describe,...
```

Empty line to quit.

### Replay a transcript

```
python3 demo/bridge.py script demo/transcripts/01_cold_discovery.llmos
```

The repo ships with eighteen transcripts - the eighteen demo beats described
below.

### Let Claude drive

```
export ANTHROPIC_API_KEY=sk-ant-...
python3 demo/bridge.py ai "Figure out what kind of machine this is."
```

The bridge hands Claude the boot banner and a tight system prompt, then
lets it issue one command per turn. It runs until Claude emits `DONE` or
the step limit is hit (default 20).

## The demo, in eighteen beats

**Beat 1 — Cold discovery.** Claude is told nothing about llmos except that
`help` exists. It walks the introspection graph — `help`, then `describe`
on each primitive — and assembles a complete capability model. Zero prior
knowledge, zero training data. The primitive list and the allowlist both
leak through introspection; the model learns the machine from inside.

Transcript: `demo/transcripts/01_cold_discovery.llmos`.

**Beat 2 — Hardware archaeology.** Task: *figure out what machine this is*.
Claude composes `cpu.vendor`, `cpu.features`, `mem.query`, `rtc.now`,
`mem.read` against the IVT and BIOS data area. From the feature flags it
dates the silicon (sse2 means post-2001). From the IVT segment it locates
the BIOS ROM. Nothing it composes was taught; the composition is the
point.

Transcript: `demo/transcripts/02_hardware_archaeology.llmos`.

**Beat 3 — The interesting failure.** Task: *read SMART status*. There is
no `disk.*` primitive. Claude reaches for `io.in` on the ATA ports at
0x1F0/0x1F7. Both denied. The schema shows the allowlist; ATA is not on
it. A listed COM1 status port succeeds, proving the same boundary has a
positive side. Claude then pivots — reads the BIOS data area for the
hard-disk count, returns a related-but-legal answer, and explains the
boundary. Denial as an interface element, not an error.

Transcript: `demo/transcripts/03_denied_path.llmos`.

**Beat 4 — PCI walk.** Task: *figure out what hardware is on the bus*.
Claude asks `help`, spots `pci.scan`, reads its schema to learn the
`B.D.F:VVVV:DDDD:CC` record shape, and scans bus 0. One line of output
names every populated function — host bridge, south bridge, IDE, display,
network — by vendor id and PCI base class. The IDE controller denied at
the port layer in beat 3 shows up here as a device: bus view and port
view are two faces of the same hardware, and llmos lets the model see
both.

Transcript: `demo/transcripts/04_pci_walk.llmos`.

**Beat 5 — BAR windows.** Task: *for each device on the bus, describe its
I/O and memory windows*. Claude takes the `BB.DD.F` records from beat 4
back into `pci.bars` and reads the six Base Address Registers per
function. It sees the framebuffer BAR on the std-vga card (32-bit,
prefetchable — that's how the CPU knows speculative reads are safe),
distinguishes it from the MMIO-register BAR on the same card (non-
prefetchable — side effects), and finds the bus-master IDE I/O window on
the PIIX3 controller whose legacy command ports beat 3 couldn't touch.
Two views of the same hardware, now fully named. The I/O BARs it reads
here are the addresses `pci.bar.read` can use to touch device registers.

Transcript: `demo/transcripts/05_bar_windows.llmos`.

**Beat 6 - BAR reads.** Task: *read a register window through a BAR*.
Claude asks for `pci.bar.read`, confirms that BAR reads are BDF- and
slot-relative, and reads a few bytes from the PIIX3 IDE bus-master I/O
window discovered in beat 5. It also tries a memory BAR and an empty BAR,
getting `denied` and `unavailable` instead of ambiguous failure. The OS
has crossed from naming hardware to reading a device-owned register
window, still through a constrained primitive.

Transcript: `demo/transcripts/06_bar_reads.llmos`.

**Beat 7 - Memory BAR reads.** Task: *read bytes from a memory-mapped
device window*. Claude uses `pci.mem.read` against the std-vga framebuffer
BAR discovered in beat 5. The implementation keeps the protocol shape
BAR-relative, but crosses the real-mode 64 KB wall by giving `FS` a flat
descriptor cache and using it only for the bounded read. I/O BARs still
deny on this primitive, preserving the split between port and memory
spaces.

Transcript: `demo/transcripts/07_mem_reads.llmos`.

**Beat 8 - Typed MMIO reads.** Task: *read a memory-mapped device
register as a typed value*. Claude uses `pci.mem.read8`, `pci.mem.read16`,
and `pci.mem.read32` against the std-vga MMIO register BAR. The kernel
still controls the address shape with `bdf`, `bar`, and `offset`, but the
response is now a decoded little-endian `value=` field instead of a byte
string the model has to unpack by hand.

Transcript: `demo/transcripts/08_typed_mem_reads.llmos`.

**Beat 9 - PCI config reads.** Task: *read raw PCI configuration registers
for a device*. Claude uses `pci.config.read` to inspect the bytes behind
the device summary: vendor/device id, command/status, class code, and a
cross-dword slice. The primitive stays bounded to the conventional
256-byte config header and reports absent functions cleanly.

Transcript: `demo/transcripts/09_config_reads.llmos`.

**Beat 10 - Typed PCI config reads.** Task: *read PCI configuration
registers as typed values*. Claude uses `pci.config.read8`,
`pci.config.read16`, and `pci.config.read32` to read the same header fields
as little-endian register values: vendor id, device id, class code, and an
unaligned-read denial.

Transcript: `demo/transcripts/10_typed_config_reads.llmos`.

**Beat 11 - PCI capability list.** Task: *list the PCI capabilities a
device advertises*. Claude uses `pci.cap.list` to ask the kernel to follow
the conventional capability linked list. QEMU's default devices return
empty lists, while CI attaches a virtio PCI device to prove non-empty chains
such as MSI-X and vendor-specific capabilities are decoded as `OFF:ID`
records.

Transcript: `demo/transcripts/11_capability_list.llmos`.

**Beat 12 - PCI capability reads.** Task: *read bytes from a PCI
capability*. Claude uses `pci.cap.read`, which requires a capability offset
returned by `pci.cap.list` and then reads relative to that capability. The
default QEMU e1000 has no conventional capabilities, so the demo shows the
structured not-found path; CI attaches a virtio PCI device and verifies a
real capability payload read.

Transcript: `demo/transcripts/12_capability_reads.llmos`.

**Beat 13 - Typed low-memory reads.** Task: *read BIOS-loaded memory as
typed values*. Claude uses `mem.read8`, `mem.read16`, and `mem.read32`
against the boot sector bytes at `7c00`. The byte-string read still exists,
but the typed siblings let the model consume little-endian values directly
and get structured alignment/range errors.

Transcript: `demo/transcripts/13_typed_memory_reads.llmos`.

**Beat 14 - Segment memory reads.** Task: *read the BIOS reset vector*.
Claude uses `mem.read.seg` to move beyond segment 0 without opening writes
or unbounded physical addressing. The demo compares `0000:7c00` with
`mem.read`, then reads the ROM bytes at `f000:fff0` and exercises the
offset-boundary and malformed-argument paths.

Transcript: `demo/transcripts/14_segment_memory_reads.llmos`.

**Beat 15 - Typed segment memory reads.** Task: *read the BIOS reset vector
as typed values*. Claude uses `mem.read.seg8`, `mem.read.seg16`, and
`mem.read.seg32` against `f000:fff0`. The byte-string view still exists, but
the typed siblings decode the same ROM bytes as little-endian values and keep
alignment/cross-segment errors structured.

Transcript: `demo/transcripts/15_typed_segment_memory_reads.llmos`.

**Beat 16 - Request line length.** Task: *prove overlong requests do not
execute a truncated prefix*. The transcript sends a request longer than the
kernel input buffer and verifies that the kernel returns `bad_arg` instead
of silently running the valid-looking command prefix.

Transcript: `demo/transcripts/16_line_length.llmos`.

**Beat 17 - No-argument validation.** Task: *treat `args=none` as a real
contract*. The transcript sends extra arguments to no-argument primitives
and verifies that each one returns a structured `bad_arg` response.

Transcript: `demo/transcripts/17_no_arg_validation.llmos`.

**Beat 18 - Describe argument validation.** Task: *keep malformed
introspection calls distinct from unknown primitive names*. The transcript
checks that `describe help x=1` returns `bad_arg`, while `describe no.such`
still returns `unknown_cmd`.

Transcript: `demo/transcripts/18_describe_arg_validation.llmos`.

Recorded outputs for all eighteen live in `demo/recordings/`.

## Layout

```
src/
  boot.asm          512 B — reset-and-retry MBR
  kernel.asm        ~15 KB - protocol loop, twenty-nine primitives, VGA mirror
Makefile            nasm, size-asserted
demo/
  bridge.py         repl / script / ai modes over QEMU -serial stdio
  transcripts/*.llmos  the eighteen demo beats, as replayable scripts
  recordings/*.txt  captured outputs of each transcript
docs/
  PROTOCOL.md       wire spec
.github/workflows/build.yml   CI
```

## What this is not

- Not a kernel you run for real work.
- Not a Unix-alike. There is no shell, no filesystem, no processes.
- Not a full protected-mode OS. It lives in 16-bit real mode and rides on
  BIOS services for everything that isn't `in`/`out`/`cpuid`.
- Not a benchmark of language-model capability. It's a demonstration of a
  *design surface* — what an OS can look like when you stop designing
  for humans.

## Limitations and honest caveats

- Single CPU, real mode only. PC/AT-compatible BIOS required. UEFI-only
  machines will refuse to boot it.
- `mem.read` reaches only the first 64 KB (segment 0 offset). `mem.read.seg`
  and its typed siblings expose other real-mode segments for bounded reads,
  but still have no writes.
- `io.out` is deliberately absent in v0.1 — the allowlist for writes wants
  more design thought than reads.
- `pci.bar.read` and `pci.mem.read` both use small bounded reads.
  `pci.mem.read` reaches only memory BARs whose base fits in 32-bit
  physical address space; it does not handle high 64-bit BARs, writes,
  interrupts, DMA, or device-specific ordering rules.
- No crypto, no storage, no networking, no interrupts of our own. Every
  non-trivial hardware interaction rides on the BIOS.
- The kernel is tiny on purpose. "Add a feature" almost always means "add
  a primitive" — the surface is the OS.

## License

Apache License 2.0. See `LICENSE`.
