#!/usr/bin/env python3
"""agent-trash: recoverable delete for coding-agent sessions.

Files are moved (never removed) into $AGENT_TRASH_DIR. The legacy
$CLAUDE_TRASH_DIR name and ~/.claude-trash default remain compatible,
one timestamped entry per invocation, with a manifest recording original paths.
"""
import argparse
import json
import os
import shutil
import sys
import time

TRASH_DIR = os.environ.get("AGENT_TRASH_DIR") or os.environ.get(
    "CLAUDE_TRASH_DIR", os.path.expanduser("~/.claude-trash")
)
MANIFEST = "manifest.json"


def entry_dirs():
    if not os.path.isdir(TRASH_DIR):
        return []
    return sorted(
        d
        for d in os.listdir(TRASH_DIR)
        if os.path.isdir(os.path.join(TRASH_DIR, d))
        and os.path.isfile(os.path.join(TRASH_DIR, d, MANIFEST))
    )


def load_manifest(entry_id):
    with open(os.path.join(TRASH_DIR, entry_id, MANIFEST)) as f:
        return json.load(f)


def unique_dest(entry_dir, basename):
    dest = os.path.join(entry_dir, basename)
    counter = 1
    while os.path.lexists(dest):
        dest = os.path.join(entry_dir, "{0}.{1}".format(basename, counter))
        counter += 1
    return dest


def cmd_put(args):
    sources = []
    for path in args.paths:
        src = os.path.abspath(path)
        if not os.path.lexists(src):
            sys.stderr.write("agent-trash: no such path: {0}\n".format(src))
            return 1
        sources.append(src)
    for index, src in enumerate(sources):
        for other in sources[:index]:
            if src == other:
                sys.stderr.write(
                    "agent-trash: duplicate source path: {0}\n".format(src)
                )
                return 1
            try:
                common = os.path.commonpath((src, other))
            except ValueError:
                continue
            if common == src or common == other:
                sys.stderr.write(
                    "agent-trash: overlapping source paths: {0} and {1}\n".format(
                        other, src
                    )
                )
                return 1
    entry_id = time.strftime("%Y%m%d-%H%M%S") + "-{0}".format(os.getpid())
    entry_dir = os.path.join(TRASH_DIR, entry_id)
    os.makedirs(entry_dir)
    manifest = {
        "id": entry_id,
        "trashed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "cwd": os.getcwd(),
        "items": [],
    }
    for src in sources:
        dest = unique_dest(entry_dir, os.path.basename(src))
        shutil.move(src, dest)
        manifest["items"].append(
            {"original": src, "stored_as": os.path.basename(dest)}
        )
    with open(os.path.join(entry_dir, MANIFEST), "w") as f:
        json.dump(manifest, f, indent=2)
    print("trashed {0} item(s) -> {1}".format(len(sources), entry_id))
    for item in manifest["items"]:
        print("  {0}".format(item["original"]))
    print("restore with: agent-trash restore {0}".format(entry_id))
    return 0


def cmd_list(args):
    entries = entry_dirs()
    if not entries:
        print("trash is empty ({0})".format(TRASH_DIR))
        return 0
    for entry_id in entries:
        manifest = load_manifest(entry_id)
        print("{0}  ({1} item(s), {2})".format(
            entry_id, len(manifest["items"]), manifest.get("trashed_at", "?")
        ))
        for item in manifest["items"]:
            print("  {0}".format(item["original"]))
    return 0


def cmd_restore(args):
    entry_dir = os.path.join(TRASH_DIR, args.id)
    if not os.path.isfile(os.path.join(entry_dir, MANIFEST)):
        sys.stderr.write("agent-trash: no such entry: {0}\n".format(args.id))
        return 1
    manifest = load_manifest(args.id)
    failures = 0
    for item in manifest["items"]:
        stored = os.path.join(entry_dir, item["stored_as"])
        original = item["original"]
        if not os.path.lexists(stored):
            sys.stderr.write("agent-trash: missing from trash: {0}\n".format(stored))
            failures += 1
            continue
        if os.path.lexists(original) and not args.force:
            sys.stderr.write(
                "agent-trash: destination exists, skipping (use --force): {0}\n".format(original)
            )
            failures += 1
            continue
        parent = os.path.dirname(original)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if os.path.lexists(original) and args.force:
            backup = unique_dest(entry_dir, os.path.basename(original) + ".displaced")
            shutil.move(original, backup)
        shutil.move(stored, original)
        print("restored {0}".format(original))
    if failures == 0:
        remaining = [n for n in os.listdir(entry_dir) if n != MANIFEST]
        if not remaining:
            shutil.rmtree(entry_dir)
    return 1 if failures else 0


def cmd_empty(args):
    if not args.yes:
        sys.stderr.write("agent-trash: empty is permanent; re-run with --yes\n")
        return 1
    cutoff = time.time() - args.older_than * 86400
    removed = 0
    for entry_id in entry_dirs():
        entry_dir = os.path.join(TRASH_DIR, entry_id)
        if os.path.getmtime(entry_dir) <= cutoff:
            shutil.rmtree(entry_dir)
            removed += 1
    print("permanently removed {0} entry(ies)".format(removed))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-trash", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_put = sub.add_parser("put", help="move paths into recoverable trash")
    p_put.add_argument("paths", nargs="+")
    p_put.set_defaults(func=cmd_put)

    p_list = sub.add_parser("list", help="show trash entries")
    p_list.set_defaults(func=cmd_list)

    p_restore = sub.add_parser("restore", help="move an entry back to its original paths")
    p_restore.add_argument("id")
    p_restore.add_argument("--force", action="store_true",
                           help="overwrite existing files at the original paths")
    p_restore.set_defaults(func=cmd_restore)

    p_empty = sub.add_parser("empty", help="permanently delete old trash entries")
    p_empty.add_argument("--older-than", type=float, default=7.0, metavar="DAYS",
                         help="only entries at least this many days old (default 7)")
    p_empty.add_argument("--yes", action="store_true")
    p_empty.set_defaults(func=cmd_empty)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
