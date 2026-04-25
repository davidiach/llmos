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
unsigned decimal integers that fit in 16 bits. Leading zeroes on decimal
values are accepted as long as the resulting value fits.

Request lines are capped at 255 bytes, excluding the trailing CR/LF. Longer
requests return `err code=bad_arg detail="request line too long"` without
executing a truncated prefix.

Primitives whose schema says `args=none` reject any argument string with
`err code=bad_arg detail="unexpected arguments"`.

`describe` accepts exactly one primitive name token. Extra tokens return
`err code=bad_arg detail="usage: describe NAME"`; a single unknown name
returns `err code=unknown_cmd detail="no such primitive"`.

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
# llmos v0.1 proto=1 primitives=29
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

## Typed low-memory reads

`mem.read addr=H len=N` reads bytes from segment 0. `len` is capped at
`1`-`256`, and reads may not cross past offset `ffff`.

`mem.read8`, `mem.read16`, and `mem.read32` read one little-endian value
from segment 0. They use the same low-memory address boundary as
`mem.read`, but return a decoded `value=` field instead of an address-order
byte string.

Arguments:

- `addr` - hex offset in segment 0 (`0`-`ffff`); `read16` and `read32`
  require natural alignment

The responses are:

```
ok addr=HHHH width=8 value=HH
ok addr=HHHH width=16 value=HHHH
ok addr=HHHH width=32 value=HHHHHHHH
```

For `mem.read16` and `mem.read32`, the hex `value` is the little-endian
numeric value loaded from memory. Out-of-range addresses, reads that would
cross past `ffff`, or unaligned multi-byte addresses return
`err code=out_of_range detail="addr or alignment out of range"`. Malformed
or missing `addr` arguments return `bad_arg`.

## Segment memory reads

`mem.read.seg seg=H offset=H len=N` reads bytes through an explicit
real-mode segment:offset pair. It is the same read-only, small bounded byte
view as `mem.read`, but the caller names the segment instead of being fixed
to segment 0.

Arguments:

- `seg` - real-mode segment value (`0`-`ffff`)
- `offset` - offset within that segment (`0`-`ffff`)
- `len` - number of bytes to read (`1`-`256`), capped so the read does not
  cross past offset `ffff`

The response is:

```
ok seg=HHHH offset=HHHH len=N data=HEX
```

`data` is emitted in address order from `seg:offset`. Reads that would
cross the end of the segment return
`err code=out_of_range detail="offset or len out of range"`. Malformed or
missing arguments return `bad_arg`.

## Typed segment memory reads

`mem.read.seg8`, `mem.read.seg16`, and `mem.read.seg32` read one
little-endian value through an explicit real-mode segment:offset pair. They
use the same segment boundary as `mem.read.seg`, but return a decoded
`value=` field instead of an address-order byte string.

Arguments:

- `seg` - real-mode segment value (`0`-`ffff`)
- `offset` - offset within that segment (`0`-`ffff`); `seg16` and `seg32`
  require natural alignment

The responses are:

```
ok seg=HHHH offset=HHHH width=8 value=HH
ok seg=HHHH offset=HHHH width=16 value=HHHH
ok seg=HHHH offset=HHHH width=32 value=HHHHHHHH
```

For `mem.read.seg16` and `mem.read.seg32`, the hex `value` is the
little-endian numeric value loaded from memory. Out-of-range offsets, reads
that would cross past `ffff`, or unaligned multi-byte offsets return
`err code=out_of_range detail="offset or alignment out of range"`.
Malformed or missing arguments return `bad_arg`.

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

## PCI config-space reads

`pci.config.read bdf=BB.DD.F offset=H len=N` reads bytes from a single
function's conventional 256-byte PCI config space. It uses the same legacy
`0xCF8`/`0xCFC` mechanism as `pci.scan` and `pci.bars`, but exposes a
small bounded byte view for fields that the higher-level summaries do not
decode yet.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `offset` - hex byte offset in config space (`0`-`ff`)
- `len` - number of bytes to read (`1`-`16`), capped so the read does not
  cross past `0xff`

The response is:

```
ok bdf=BB.DD.F offset=HH len=N data=HEX
```

`data` is emitted in address order. For example, vendor/device id at offset
`0` is returned as the two little-endian id words laid out in config space.

If the function is absent, the response is
`err code=unavailable detail="no such function"`. Malformed BDFs or missing
arguments return `bad_arg`. Out-of-range offsets, lengths, or reads that
would cross past `0xff` return
`err code=out_of_range detail="offset or len out of range"`.

## PCI typed config-space reads

`pci.config.read8`, `pci.config.read16`, and `pci.config.read32` read one
little-endian value from a single function's conventional PCI config space.
They use the same BDF and bounded offset policy as `pci.config.read`, but
return a decoded `value=` field instead of address-order bytes.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `offset` - hex byte offset in config space (`0`-`ff`); `read16` and
  `read32` require natural alignment

The responses are:

```
ok bdf=BB.DD.F offset=HH width=8 value=HH
ok bdf=BB.DD.F offset=HH width=16 value=HHHH
ok bdf=BB.DD.F offset=HH width=32 value=HHHHHHHH
```

For `read16` and `read32`, the hex `value` is the little-endian numeric
value loaded from config space, not the address-order byte string that
`pci.config.read` returns. Out-of-range offsets or unaligned multi-byte
offsets return
`err code=out_of_range detail="offset or alignment out of range"`. Absent
functions and malformed BDFs use the same errors as `pci.config.read`.

## PCI capability listing

`pci.cap.list bdf=BB.DD.F` follows a function's conventional PCI
capability linked list. It first checks status bit 4 at config offset
`0x06`; if the function does not advertise a capability list, the response
is still successful with an empty `caps=` field.

The response is:

```
ok bdf=BB.DD.F caps=OFF:ID[,OFF:ID...] truncated=N malformed=N
```

`OFF` is the two-digit config-space offset of a capability header, and
`ID` is the two-digit PCI capability id at that offset. The next pointer is
not emitted because the kernel has already consumed it to produce the list;
callers can use `pci.config.read` on an offset if they need capability
payload bytes.

The walk is bounded to 48 capability headers so cycles cannot hang the
protocol. `truncated=1` means the bound was reached before a null next
pointer. `malformed=1` means a non-null pointer landed outside the normal
conventional capability area. In both cases the response remains a single
structured `ok` line with whatever records were safely read. Absent
functions return `err code=unavailable detail="no such function"`;
malformed BDFs return `bad_arg`.

## PCI capability-relative reads

`pci.cap.read bdf=BB.DD.F cap=H offset=H len=N` reads bytes relative to a
capability header returned by `pci.cap.list`. `cap` is the capability
offset, not the capability id; this keeps the request unambiguous when a
device exposes more than one capability with the same id.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `cap` - a dword-aligned capability offset from `pci.cap.list`
- `offset` - hex byte offset relative to the capability header
- `len` - number of bytes to read (`1`-`16`), capped so the effective
  config-space read does not cross past `0xff`

The response is:

```
ok bdf=BB.DD.F cap=HH id=HH offset=HH len=N data=HEX
```

`id` repeats the capability id found at `cap`, and `data` is emitted in
address order from `cap + offset`. If `cap` is well-formed but not present
in the capability chain, the response is
`err code=unavailable detail="capability not found"`. Malformed BDFs or
missing arguments return `bad_arg`; out-of-range capability offsets,
relative offsets, lengths, or reads that would cross past `0xff` return
`err code=out_of_range detail="cap, offset, or len out of range"`.

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

## BAR-bound I/O reads

`pci.bar.read bdf=BB.DD.F bar=N offset=H len=N` reads bytes from an
I/O-space BAR discovered through `pci.bars`. It is intentionally
BAR-relative: the caller names a PCI function, chooses one BAR slot, and
uses a small offset from that BAR rather than an arbitrary port number.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `bar` - decimal BAR slot index (`0`-`5`, further capped by header type)
- `offset` - hex byte offset from the BAR base (`0`-`ff`)
- `len` - number of bytes to read (`1`-`16`)

The response is:

```
ok bdf=BB.DD.F bar=N kind=io port=HHHH offset=HHHH len=N data=HEX
```

`port` is the effective 16-bit I/O port after adding `offset` to the BAR
base. `data` is `len` bytes read with 8-bit `in` instructions and
hex-encoded in order.

If the function is absent, the response is
`err code=unavailable detail="no such function"`. If the selected BAR is
empty, the response is `err code=unavailable detail="BAR not present"`.
If the BAR is memory-space rather than I/O-space, the response is
`err code=denied detail="only I/O BAR reads are supported"`. Out-of-range
slot, offset, length, or effective port values return `out_of_range`.

## BAR-bound memory reads

`pci.mem.read bdf=BB.DD.F bar=N offset=H len=N` reads bytes from a
memory-space BAR discovered through `pci.bars`. It has the same
BAR-relative shape as `pci.bar.read`: the caller names a PCI function,
chooses a BAR slot, and gives a small offset and length rather than a raw
physical address.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `bar` - decimal BAR slot index (`0`-`5`, further capped by header type)
- `offset` - hex byte offset from the BAR base (`0`-`ff`)
- `len` - number of bytes to read (`1`-`16`)

The response is:

```
ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH len=N data=HEX
```

`addr` is the effective physical address after adding `offset` to the BAR
base. `data` is `len` bytes read through a flat `FS` descriptor cache and
hex-encoded in order. The kernel sets up that flat `FS` cache with a small
unreal-mode transition; normal `DS`, `ES`, and `SS` remain real-mode
segments.

If the function is absent, the response is
`err code=unavailable detail="no such function"`. If the selected BAR is
empty, the response is `err code=unavailable detail="BAR not present"`.
If the BAR is I/O-space rather than memory-space, the response is
`err code=denied detail="only memory BAR reads are supported"`. Reserved,
malformed, or high 64-bit memory BARs are rejected; a 64-bit memory BAR is
readable only when its high dword is zero. Out-of-range slot, offset,
length, or effective physical address values return `out_of_range`.

## BAR-bound typed memory reads

`pci.mem.read8`, `pci.mem.read16`, and `pci.mem.read32` read one
little-endian value from a memory-space BAR discovered through `pci.bars`.
They use the same BAR-relative addressing policy as `pci.mem.read`, but
return a decoded `value=` field instead of a byte string.

Arguments:

- `bdf` - same `BB.DD.F` tuple emitted by `pci.scan`
- `bar` - decimal BAR slot index (`0`-`5`, further capped by header type)
- `offset` - hex byte offset from the BAR base (`0`-`ff`); `read16` and
  `read32` require natural alignment

The responses are:

```
ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH width=8 value=HH
ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH width=16 value=HHHH
ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH width=32 value=HHHHHHHH
```

`addr` is the effective physical address after adding `offset` to the BAR
base. `width` is the value width in bits. For `read16` and `read32`, the
hex `value` is the little-endian numeric value loaded from MMIO, not the
address-order byte string that `pci.mem.read` returns.

The same memory-BAR restrictions and error behavior apply: I/O BARs are
denied, empty BARs are unavailable, unsupported memory BARs are unavailable,
and high 64-bit addresses are out of range. Out-of-range BAR slots,
offsets, or unaligned multi-byte offsets return
`err code=out_of_range detail="bar, offset, or alignment out of range"`.
