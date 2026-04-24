# llmos wire protocol v1

## Transport

COM1 at 115200 baud, 8 data bits, no parity, 1 stop bit. Hardware flow
control is not used; the protocol is self-delimiting by newlines.

## Record format

Every record is a single line terminated by `\n`. Lines may also include
`\r`; the kernel strips it. Records come in three types, distinguished by
the first character when the bridge logs them:

```
>  request from the user (sent by the bridge to the kernel)
<  response from the kernel
#  unsolicited kernel message — banner, event, or comment
```

The `>` and `<` prefixes are *conventions of the bridge's display* — the
kernel itself sends only the content and a trailing `\n`. The `#` prefix IS
emitted by the kernel for system messages.

## Requests

```
CMD [KEY=VALUE ...]
```

`CMD` is a single token (no whitespace). `KEY=VALUE` pairs are
space-separated and may appear in any order. Values are either unquoted
tokens (no whitespace), hexadecimal (1–4 digits, case-insensitive), or
decimal integers.

Examples:
```
help
describe cpu.vendor
mem.read addr=7c00 len=16
io.in port=70
```

## Responses

Every response line begins with exactly one of:

- `ok [KEY=VALUE ...]` — success, with zero or more fields
- `err code=CODE detail="HUMAN READABLE"` — failure

Error codes in v1:

| Code            | Meaning                                            |
| --------------- | -------------------------------------------------- |
| `unknown_cmd`   | The command name is not a registered primitive.    |
| `bad_arg`       | Arguments are missing, malformed, or unparseable.  |
| `out_of_range`  | An argument is valid in format but out of bounds.  |
| `denied`        | The operation is blocked by policy (e.g. `io.in`). |
| `unavailable`   | The underlying resource did not respond.           |
| `timeout`       | (Bridge-side only) The kernel did not reply.       |

## Value encodings

- **Strings:** unquoted when they match `[A-Za-z0-9._-]+`, otherwise wrapped
  in double quotes with no escape syntax (the kernel never emits a `"`
  inside a quoted string).
- **Integers (decimal):** `ms=2805`, `family=6`.
- **Hex integers:** lowercase, no `0x` prefix, exactly as many digits as the
  field calls for (`value=00`, `port=0070`, `addr=7c00`).
- **Hex blobs:** lowercase, concatenated, no separator (`data=fa31c08e…`).
  Length is always included as a separate `len=` field so the reader can
  split without parsing.
- **Comma-separated lists:** no spaces after commas
  (`features=fpu,de,pse,tsc`).

## Boot banner

On reset, the kernel sets up serial and emits:

```
# llmos v0.1 proto=1 primitives=11
```

A bridge MUST wait for a line whose first character is `#` before sending
any command. The banner acts as a readiness signal.

## One transaction per request

The kernel emits exactly one response line per request. There is no
streaming, no framing other than `\n`, no interleaved events. The bridge
can safely pair each sent request with the next received line.

## Multi-line payloads

Not supported in v1. Binary payloads are hex-encoded inline on the same
response line (see `mem.read`). This costs 2× bandwidth in exchange for
single-line parseability. A future version may add a `data:` framing
sentinel for larger blobs.

## Allowlist for privileged primitives

`io.in` is restricted to a hard-coded allowlist of ports compiled into the
kernel. The allowlist is introspectable — `describe io.in` includes the
full list in its response. Attempting to read a non-allowed port yields
`err code=denied detail="port not in allowlist"`. This is deliberate: a
model discovers the boundary by bumping into it, and can see the boundary
by asking.

## PCI enumeration

`pci.scan` walks the PCI topology using the legacy config mechanism —
writes the enable bit plus bus/device/function/register to `0xCF8`, reads
the dword from `0xCFC`. Scanning always starts at bus 0. When a function's
header type (bits 0..6 of config offset 0x0E) is `0x01`, it is a
PCI-to-PCI bridge; the kernel reads the secondary bus number at config
offset 0x19 and enqueues that bus for scanning. The response therefore
covers the full reachable tree, in bus-ascending order. Each populated
function contributes one record:

```
ok devices=B.D.F:VVVV:DDDD:CC[,B.D.F:VVVV:DDDD:CC ...]
```

Fields, all lowercase hex, fixed-width:

- `B` — bus number (2 digits, `00` for the root bus, higher for buses
  discovered behind bridges)
- `D` — device number (2 digits, `00`–`1f`)
- `F` — function number (1 digit, `0`–`7`)
- `VVVV` — vendor id at config offset 0x00
- `DDDD` — device id at config offset 0x02
- `CC` — base class byte at config offset 0x0B

Multi-function devices are detected via bit 7 of the header-type byte
(config offset 0x0E); single-function devices report only function 0.
An empty scan yields `ok devices=` with no records.

## BAR decoding

`pci.bars bdf=BB.DD.F` decodes the Base Address Registers of a single
function. The `BB.DD.F` tuple matches the record shape `pci.scan` emits.
The number of BAR slots depends on the header type at config offset 0x0E:

| Header type | Slots | Config offsets       |
| ----------- | ----- | -------------------- |
| `0x00`      | 6     | 0x10, 0x14, …, 0x24  |
| `0x01`      | 2     | 0x10, 0x14           |
| other       | 0     | —                    |

The response is:

```
ok bdf=BB.DD.F bars=I:KIND[:BASE[:p|n]][,I:KIND[:BASE[:p|n]] ...]
```

One record per slot, comma-separated, in ascending slot order. `KIND`
names the encoding in the low three bits of the raw BAR dword:

| Record form              | Raw encoding                                 |
| ------------------------ | -------------------------------------------- |
| `I:none`                 | raw dword is zero — slot is unused           |
| `I:io:BASE32`            | bit 0 = 1 — I/O space BAR                    |
| `I:m32:BASE32:p\|n`      | bit 0 = 0, type bits [2:1] = 00 — 32-bit mem |
| `I:m64:BASE64:p\|n`      | bit 0 = 0, type bits [2:1] = 10 — 64-bit mem |
| `I:m64trunc:BASE32:p\|n` | 64-bit BAR declared on the last slot         |
| `I:mlt1:BASE32:p\|n`     | bit 0 = 0, type bits [2:1] = 01 — legacy     |
| `I:rsv:BASE32:p\|n`      | bit 0 = 0, type bits [2:1] = 11 — reserved   |

`BASE32` is eight lowercase hex digits. `BASE64` is sixteen lowercase
hex digits (high dword first, then low dword). `p` marks the memory
BAR as prefetchable (bit 3 of the low dword set), `n` as non-
prefetchable. A 64-bit memory BAR consumes the next slot as its high
dword; the consumed slot is skipped in the list (the indices are
non-contiguous). `m64trunc` is emitted only for a self-contradictory
device that declares a 64-bit BAR on the last available slot (no room
for the high dword); only the low 32 bits of the base are reported.

An unpopulated function (vendor id reads as `ffff`) yields
`err code=unavailable detail="no such function"`. A malformed `bdf`
argument, including trailing junk after the function digit, yields
`err code=bad_arg`.
