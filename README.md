# llmos

[![build](https://github.com/davidiach/llmos/actions/workflows/build.yml/badge.svg)](https://github.com/davidiach/llmos/actions/workflows/build.yml)

*An operating system whose primary user is a language model.*

llmos is a sub-16 KiB real-mode x86 kernel whose entire interaction surface is
a line-oriented text protocol over COM1. There is no keyboard reader and no
human prompt. Every capability is exposed as a small primitive with a typed
request and a single-line response.

The model bootstraps its understanding of the machine from inside the machine:
`help` lists available primitives, `describe NAME` returns a schema for one
primitive, and from there the model composes.

```text
# abridged transcript
# llmos v0.1 proto=1 primitives=29
> help
< ok primitives=help,describe,cpu.vendor,...,pci.mem.read32
> cpu.vendor
< ok vendor=GenuineIntel family=6 model=6 stepping=3
> mem.read addr=7c00 len=16
< ok addr=7c00 len=16 data=fa31c08ed88ec08ed0bc007cfbfc8816
> io.in port=1f0
< err code=denied detail="port not in allowlist"
```

## Why

Operating systems have traditionally been designed for humans to drive:
shells, prompts, flags, man pages, ioctls, implicit state, and prose-heavy
errors. Language models are a different kind of user. They benefit from
explicit primitives, structured responses, discoverable capability surfaces,
and errors that are useful control-flow signals.

llmos asks a narrow question: what does an OS interface look like if an LLM is
the primary operator rather than an adapter bolted onto a human terminal?

## Design commitments

**One input channel.** COM1 only. The kernel has no keyboard driver. A
human-driven TTY would be a different OS.

**One transaction per primitive.** Every request produces exactly one response
line. There is no streaming, no interleaving, and no framing beyond `\n`.

**Structured over prose.** Responses are `ok key=value ...` or
`err code=X detail="..."`. The error vocabulary is intentionally small:
`unknown_cmd`, `bad_arg`, `out_of_range`, `denied`, `unavailable`, and
`timeout`.

**Discoverable surface.** `help` returns the primitive list. `describe NAME`
returns the arguments, response fields, and relevant policy details for one
primitive.

**Errors as interface.** A denied operation is still informative. For example,
`io.in port=1f0` returns `denied`; `describe io.in` then shows the allowlist
the model can legally use.

**Human-observable.** Every request and response mirrors to VGA text mode, so
an audience can watch the same transcript the model sees. Launch with
`make run-gui` to see the mirror in QEMU.

## Current surface

The v0.1 kernel exposes 29 primitives:

- Introspection: `help`, `describe`
- CPU and time: `cpu.vendor`, `cpu.features`, `rtc.now`, `ticks.since_boot`
- Memory query and bounded reads: `mem.query`, segment-0 reads, explicit
  segment:offset reads, and typed 8/16/32-bit variants
- Allowlisted I/O reads through `io.in`
- PCI discovery, config-space reads, capability traversal, BAR decoding, and
  small BAR-relative I/O/MMIO reads

The full wire format and primitive-by-primitive behavior live in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Running it

### Requirements

- `nasm`
- `qemu-system-i386`
- `make`, `dd`, `sed`, `timeout`
- `python3` for the bridge
- `pip install anthropic` only if you want to use the bundled AI bridge

### Build and check

```sh
make               # build/llmos.img
make test-bridge   # run bridge unit tests
make smoke         # replay shipped transcripts through QEMU
make check         # build + bridge tests + transcript smoke
make ci-check      # build + bridge tests + extended protocol smoke
make run           # run in QEMU, COM1 on stdio, VGA suppressed
make run-gui       # run in QEMU with the VGA window visible
make debug         # paused at start, gdb stub on :1234
```

### Drive it yourself

Shortcut that builds first:

```sh
./run.sh
```

Or run the bridge directly after `make`:

```sh
python3 demo/bridge.py repl
> help
< ok primitives=help,describe,...
```

Send an empty line to quit.

### Replay a transcript

```sh
python3 demo/bridge.py script demo/transcripts/01_cold_discovery.llmos
```

The repo ships with twenty-one replayable demo transcripts and matching
recorded outputs. See [docs/DEMO.md](docs/DEMO.md) for the walkthrough.

### Let an LLM drive

The included AI bridge currently targets Anthropic's API. The OS protocol
itself is model-agnostic.

```sh
export ANTHROPIC_API_KEY=sk-ant-...
# optional: override the default model, currently claude-opus-4-7
export ANTHROPIC_MODEL=claude-opus-4-7
python3 demo/bridge.py ai "Figure out what kind of machine this is."
```

The bridge gives the model the boot banner and a tight system prompt, then
allows one primitive call per turn until the model emits `DONE` or the step
limit is reached.

## Layout

```text
src/
  boot.asm          512 B reset-and-retry MBR
  kernel.asm        ~16 KB protocol loop, primitives, VGA mirror
demo/
  bridge.py         repl / script / ai modes over QEMU serial
  transcripts/      replayable demo scripts
  recordings/       captured outputs for those scripts
docs/
  PROTOCOL.md       wire spec and primitive reference
  DEMO.md           guided tour of the demo transcripts
.github/workflows/build.yml
Makefile
```

## Status

llmos is a research prototype and design-surface demonstration, not a kernel
for real work. It is intentionally small, read-only in the dangerous places,
and built around a constrained protocol boundary.

It is not a Unix-like system: there is no shell, filesystem, process model,
networking stack, storage stack, or protected-mode driver environment. It
targets the legacy x86 PC/AT boot path under QEMU, starts in 16-bit real mode,
and relies on BIOS services for everything that is not direct `in`, `out`, or
`cpuid`.

Current caveats:

- Single CPU, real mode only. PC/AT-compatible BIOS required.
- UEFI-only machines will not boot it.
- Memory primitives are read-only and bounded.
- `io.out` is deliberately absent in v0.1.
- `ticks.since_boot` is intended for short demo sessions, not multi-day
  uptime accounting.
- PCI BAR reads are small, bounded probes; high 64-bit MMIO addresses, writes,
  interrupts, DMA, and device-specific ordering rules are out of scope.

The kernel is tiny on purpose. Adding a feature usually means adding a
primitive; the surface is the OS.

## License

Apache License 2.0. See [LICENSE](LICENSE).
