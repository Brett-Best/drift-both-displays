#!/usr/bin/env python3
"""Convert an exact copied Drift executable slice into a loadable bundle."""

from __future__ import annotations

import argparse
from pathlib import Path


PATCHES = (
    (0x0C, bytes.fromhex("02000000"), bytes.fromhex("08000000")),
    (0x18, bytes.fromhex("85002004"), bytes.fromhex("85000004")),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    data = bytearray(args.binary.read_bytes())
    for offset, expected, replacement in PATCHES:
        actual = bytes(data[offset : offset + len(expected)])
        if actual != expected:
            raise SystemExit(
                f"unexpected bytes at 0x{offset:x}: expected {expected.hex()}, "
                f"found {actual.hex()}"
            )
        data[offset : offset + len(replacement)] = replacement
        print(f"patched header 0x{offset:x}: {expected.hex()} -> {replacement.hex()}")
    args.binary.write_bytes(data)


if __name__ == "__main__":
    main()
