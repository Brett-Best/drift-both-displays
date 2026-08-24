#!/usr/bin/env python3
"""Create a wallpaper Index.plist selecting a specific screen-saver bundle."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Write a modified copy of a wallpaper Index.plist."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("bundle_url")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    if args.source.resolve() == args.destination.resolve():
        raise SystemExit("destination must differ from source")
    if args.destination.exists():
        raise SystemExit(f"refusing to overwrite destination: {args.destination}")

    with args.source.open("rb") as source_file:
        index = plistlib.load(source_file)

    configuration = plistlib.dumps(
        {"module": {"relative": args.bundle_url}},
        fmt=plistlib.FMT_BINARY,
        sort_keys=False,
    )
    for root_name in ("AllSpacesAndDisplays", "SystemDefault"):
        choice = index[root_name]["Idle"]["Content"]["Choices"][0]
        choice["Configuration"] = configuration

    args.destination.parent.mkdir(parents=True, exist_ok=True)
    with args.destination.open("xb") as destination_file:
        plistlib.dump(
            index,
            destination_file,
            fmt=plistlib.FMT_BINARY,
            sort_keys=False,
        )


if __name__ == "__main__":
    main()
