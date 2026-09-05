#!/usr/bin/env python3
"""Create or verify the runtime copies needed by cached agent plugins.

Claude and Codex execute their installed package in isolation, so their adapter
roots must each contain the hook and CLI runtime. These files are generated
from the repository root; never edit a copy by hand.
"""
from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path


RUNTIME_FILES = (
    Path("hooks/trash_guard.py"),
    Path("bin/agent-trash"),
    Path("bin/claude-trash"),
    Path("lib/agent_trash.py"),
)
TARGETS = (Path("integrations/claude"), Path("integrations/codex"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail on stale generated copies")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    stale: list[Path] = []
    for target in TARGETS:
        for relative_path in RUNTIME_FILES:
            source = root / relative_path
            destination = root / target / relative_path
            if not destination.is_file() or not filecmp.cmp(source, destination, shallow=False):
                stale.append(destination.relative_to(root))
                if not args.check:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
    if stale and args.check:
        print("generated platform bundles are stale:", file=sys.stderr)
        for path in stale:
            print(f"  {path}", file=sys.stderr)
        print("run: python3 tools/build_platform_bundles.py", file=sys.stderr)
        return 1
    if not args.check:
        print("platform bundles are synchronized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
