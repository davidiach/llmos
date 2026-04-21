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
# llmos v0.1 proto=1 primitives=9
> help
< ok primitives=help,describe,cpu.vendor,cpu.features,mem.query,mem.read,rtc.now,ticks.since_boot,io.in
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
| `rtc.now`          | none                        | `iso=YYYY-MM-DDTHH:MM:SS`                       |
| `ticks.since_boot` | none                        | `ms=N`                                          |
| `io.in`            | `port=H`                    | `port=H value=H` or `err code=denied`           |

`io.in`'s allowlist is introspectable: `describe io.in` includes the full
list. At the moment it covers the PIC (0x20, 0x21), PIT (0x40, 0x43),
keyboard controller (0x60, 0x61, 0x64), CMOS (0x70, 0x71), and COM1
itself (0x3F8–0x3FF).

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

The repo ships with three transcripts — the three demo beats described
below.

### Let Claude drive

```
export ANTHROPIC_API_KEY=sk-ant-...
python3 demo/bridge.py ai "Figure out what kind of machine this is."
```

The bridge hands Claude the boot banner and a tight system prompt, then
lets it issue one command per turn. It runs until Claude emits `DONE` or
the step limit is hit (default 20).

## The demo, in three beats

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
it. Claude pivots — reads the BIOS data area for the hard-disk count,
returns a related-but-legal answer, and explains the boundary. Denial as
an interface element, not an error.

Transcript: `demo/transcripts/03_denied_path.llmos`.

Recorded outputs for all three live in `demo/recordings/`.

## Layout

```
src/
  boot.asm          512 B — reset-and-retry MBR
  kernel.asm        ~3.6 KB — protocol loop, nine primitives, VGA mirror
Makefile            nasm, size-asserted
demo/
  bridge.py         repl / script / ai modes over QEMU -serial stdio
  transcripts/*.llmos  the three demo beats, as replayable scripts
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
- `mem.read` reaches only the first 64 KB (segment 0 offset). No
  segment-switching primitive yet.
- `io.out` is deliberately absent in v0.1 — the allowlist for writes wants
  more design thought than reads.
- No PCI enumeration yet. `pci.scan` is the obvious next primitive.
- No crypto, no storage, no networking, no interrupts of our own. Every
  non-trivial hardware interaction rides on the BIOS.
- The kernel is tiny on purpose. "Add a feature" almost always means "add
  a primitive" — the surface is the OS.

## License

Apache License 2.0. See `LICENSE`.
