#!/usr/bin/env python3
"""Report approximate top-level label sizes from a NASM listing."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
LISTING_ADDR_RE = re.compile(r"^\s*(\d+)\s+([0-9A-Fa-f]{8})\b")


def source_labels(source: Path) -> list[tuple[int, str]]:
    labels: list[tuple[int, str]] = []
    for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
        match = LABEL_RE.match(line)
        if match is not None:
            labels.append((line_number, match.group(1)))
    return labels


def listing_addresses(listing: Path) -> list[tuple[int, int]]:
    addresses: list[tuple[int, int]] = []
    seen_source_lines: set[int] = set()
    for line in listing.read_text(encoding="utf-8").splitlines():
        match = LISTING_ADDR_RE.match(line)
        if match is None:
            continue
        source_line = int(match.group(1))
        if source_line in seen_source_lines:
            continue
        seen_source_lines.add(source_line)
        addresses.append((source_line, int(match.group(2), 16)))
    return addresses


def label_starts(
    labels: list[tuple[int, str]],
    addresses: list[tuple[int, int]],
) -> list[tuple[str, int, int]]:
    starts: list[tuple[str, int, int]] = []
    address_index = 0
    for line_number, label in labels:
        while (
            address_index < len(addresses)
            and addresses[address_index][0] < line_number
        ):
            address_index += 1
        if address_index < len(addresses):
            starts.append((label, line_number, addresses[address_index][1]))
    return starts


def label_spans(
    starts: list[tuple[str, int, int]],
    binary_size: int,
) -> list[tuple[int, int, int, str]]:
    spans: list[tuple[int, int, int, str]] = []
    for index, (label, line_number, start) in enumerate(starts):
        next_start = binary_size
        for _next_label, _next_line, candidate in starts[index + 1 :]:
            if candidate > start:
                next_start = candidate
                break
        size = max(0, next_start - start)
        spans.append((size, start, line_number, label))
    return spans


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listing", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--budget", required=True, type=int)
    parser.add_argument("--source", default=Path("src/kernel.asm"), type=Path)
    parser.add_argument("--limit", default=30, type=int)
    args = parser.parse_args()

    binary_size = args.binary.stat().st_size
    free = args.budget - binary_size
    starts = label_starts(
        source_labels(args.source),
        listing_addresses(args.listing),
    )
    spans = sorted(label_spans(starts, binary_size), reverse=True)

    print(f"kernel: {binary_size} B / {args.budget} B budget ({free} B free)")
    print("largest top-level labels:")
    for size, start, line_number, label in spans[: args.limit]:
        if size == 0:
            continue
        print(f"{size:5d} B  {start:04x}  line {line_number:4d}  {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
