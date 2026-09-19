#!/usr/bin/env python3
"""agent-trash: recoverable delete for coding-agent sessions.

Files are moved (never removed) into $AGENT_TRASH_DIR. The legacy
$CLAUDE_TRASH_DIR name and ~/.claude-trash default remain compatible,
one timestamped entry per invocation, with a manifest recording original paths.

The `gc` subcommand closes the other half of the problem: a recoverable delete
that is never reaped just fills the disk with quarantined garbage. `gc` reclaims
accumulated storage under a size budget, and only ever reclaims what a
reachability check proves nothing still points at.
"""
import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time

TRASH_DIR = os.environ.get("AGENT_TRASH_DIR") or os.environ.get(
    "CLAUDE_TRASH_DIR", os.path.expanduser("~/.claude-trash")
)
MANIFEST = "manifest.json"

# Each host bundle (repo root, integrations/claude, integrations/codex) carries
# a byte-identical copy of this file alongside its own plugin manifest. Read
# the version from that manifest rather than hard-coding a second copy here.
_MANIFEST_CANDIDATES = (
    "plugin.json",
    os.path.join(".codex-plugin", "plugin.json"),
    os.path.join(".claude-plugin", "plugin.json"),
)


def bundle_version():
    bundle_root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    for candidate in _MANIFEST_CANDIDATES:
        manifest_path = os.path.join(bundle_root, candidate)
        if os.path.isfile(manifest_path):
            try:
                with open(manifest_path) as f:
                    return json.load(f).get("version", "unknown")
            except (OSError, ValueError):
                continue
    return "unknown"


VERSION = bundle_version()


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


# --------------------------------------------------------------------------
# garbage collection: budget decides WHEN, reachability decides WHAT
# --------------------------------------------------------------------------
#
# The decision ladder below is evaluated top to bottom, first match wins. It is
# implemented once, in gc_decide(), so that no second code path can invent a
# different order. Every receipt names the rule number that decided it.
#
#   1. PROTECTED  never collect. Absolute, overrides everything below.
#   2. UNKNOWN    git could not answer; unknown is treated as reachable.
#   3. REACHABLE  dirty tree, stash, unpushed commits, or a branch head that
#                 `git ls-remote` did not confirm on a real remote.
#   4. TOO YOUNG  newer than --older-than. Budget pressure never overrides it.
#   5. BUDGET     only now: if the footprint exceeds --budget, collect the
#                 remaining candidates oldest-first until it is under budget.
#   6. DEFAULT    do not collect.

GC_RULE_PROTECTED = 1
GC_RULE_UNKNOWN = 2
GC_RULE_REACHABLE = 3
GC_RULE_TOO_YOUNG = 4
GC_RULE_BUDGET = 5
GC_RULE_DEFAULT = 6

GC_RULE_NAMES = {
    GC_RULE_PROTECTED: "protected",
    GC_RULE_UNKNOWN: "unknown",
    GC_RULE_REACHABLE: "reachable",
    GC_RULE_TOO_YOUNG: "too-young",
    GC_RULE_BUDGET: "budget",
    GC_RULE_DEFAULT: "default",
}

# Hard invariants. These are not configurable away; --protect only adds to them.
GC_PROTECTED_DEFAULT = ("~/.claude", "~/ai-infra", "~/github-projects")
GC_PROTECTED_NAMES = ("profiles.db", "corpus.db")

GC_SIZE_UNITS = {
    "": 1, "B": 1, "K": 1024, "M": 1024 ** 2,
    "G": 1024 ** 3, "T": 1024 ** 4, "P": 1024 ** 5,
}

# git must never be able to block on a credential or host-key prompt: a hung
# check is an unanswered question, and an unanswered question is UNKNOWN.
GC_GIT_ENV = {
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_ASKPASS": "echo",
    "SSH_ASKPASS": "echo",
    "GIT_SSH_COMMAND": "ssh -oBatchMode=yes -oConnectTimeout=10",
    "GIT_OPTIONAL_LOCKS": "0",
    "GCM_INTERACTIVE": "never",
    "LC_ALL": "C",
}


class GitUnknown(Exception):
    """git could not answer a reachability question.

    A failed, timed-out or unparseable git call is never evidence of
    cleanliness. Every caller converts this into an UNKNOWN verdict, which
    rule 2 refuses to collect. This exists specifically to stop a `dirty=0`
    that was produced by git falling over from reading as "safe to delete".
    """

    def __init__(self, evidence):
        Exception.__init__(self, evidence.get("detail", "git check failed"))
        self.evidence = evidence


def parse_size(text):
    """Parse 5G / 500M / 1.5TiB / 1024 into bytes (base 1024)."""
    raw = str(text).strip().upper()
    if not raw:
        raise ValueError("empty size")
    if raw.endswith("IB"):
        raw = raw[:-2]
    elif len(raw) > 1 and raw.endswith("B") and raw[-2] in "KMGTP":
        raw = raw[:-1]
    unit = ""
    if raw and raw[-1] in GC_SIZE_UNITS and raw[-1] != "":
        unit = raw[-1]
        raw = raw[:-1]
    try:
        value = float(raw)
    except ValueError:
        raise ValueError("not a size: {0}".format(text))
    if value < 0:
        raise ValueError("negative size: {0}".format(text))
    return int(value * GC_SIZE_UNITS[unit])


def size_arg(text):
    try:
        return parse_size(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc))


def human_size(count):
    value = float(count)
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024.0 or unit == "T":
            if unit == "B":
                return "{0:.0f}B".format(value)
            return "{0:.1f}{1}".format(value, unit)
        value /= 1024.0
    return "{0:.1f}P".format(value)


def path_within(child, parent):
    try:
        return os.path.commonpath((child, parent)) == parent
    except ValueError:
        return False


def git_binary():
    return os.environ.get("AGENT_TRASH_GIT", "git")


def run_git(repo, argv, timeout, allowed=(0,), stdin_data=None):
    """Run git, converting every failure mode into GitUnknown.

    Returns (exit_code, stdout). Only exit codes in `allowed` come back; any
    other code, any OSError and any timeout raise GitUnknown.
    """
    command = [git_binary(), "-C", repo] + list(argv)
    printable = "git " + " ".join(argv)
    env = dict(os.environ)
    env.update(GC_GIT_ENV)
    try:
        proc = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=env,
            input=None if stdin_data is None else stdin_data.encode("utf-8"),
        )
    except subprocess.TimeoutExpired:
        raise GitUnknown({
            "check": argv[0], "command": printable, "exit_code": None,
            "result": "unknown",
            "detail": "timed out after {0:g}s".format(timeout),
        })
    except OSError as exc:
        raise GitUnknown({
            "check": argv[0], "command": printable, "exit_code": None,
            "result": "unknown",
            "detail": "could not run git: {0}".format(exc),
        })
    out = proc.stdout.decode("utf-8", "replace")
    if proc.returncode not in allowed:
        err = proc.stderr.decode("utf-8", "replace").strip().replace("\n", " ")
        raise GitUnknown({
            "check": argv[0], "command": printable,
            "exit_code": proc.returncode, "result": "unknown",
            "detail": "git exited {0}: {1}".format(proc.returncode, err[:400]),
        })
    return proc.returncode, out


def remote_is_local(url):
    if "://" in url:
        return url.startswith("file://")
    if "@" in url.split("/")[0] and ":" in url.split("/")[0]:
        return False  # scp-style host:path
    return os.path.isdir(url) or os.path.isdir(url + "/objects")


def checkout_reachability(repo, options, remote_cache):
    """Decide whether one git checkout is unreachable (safe to collect).

    Returns (verdict, evidence) where verdict is one of
    "unreachable" / "reachable" / "unknown".
    """
    evidence = []

    def note(check, command, exit_code, result, detail):
        evidence.append({
            "check": check, "command": command, "exit_code": exit_code,
            "result": result, "detail": detail,
        })

    timeout = options["git_timeout"]
    try:
        code, out = run_git(repo, ["rev-parse", "--show-toplevel"], timeout)
        note("worktree", "git rev-parse --show-toplevel", code, "ok",
             out.strip() or repo)

        code, out = run_git(
            repo, ["status", "--porcelain", "--untracked-files=all"], timeout
        )
        changed = [line for line in out.splitlines() if line.strip()]
        if changed:
            note("dirty", "git status --porcelain --untracked-files=all", code,
                 "reachable",
                 "{0} uncommitted path(s), first: {1}".format(
                     len(changed), changed[0].strip()))
            return "reachable", evidence
        note("dirty", "git status --porcelain --untracked-files=all", code,
             "clean", "0 uncommitted paths")

        code, out = run_git(repo, ["stash", "list"], timeout)
        stashes = [line for line in out.splitlines() if line.strip()]
        if stashes:
            note("stash", "git stash list", code, "reachable",
                 "{0} stash entry(ies), first: {1}".format(
                     len(stashes), stashes[0].strip()))
            return "reachable", evidence
        note("stash", "git stash list", code, "clean", "0 stash entries")

        code, out = run_git(repo, ["remote"], timeout)
        remotes = [line.strip() for line in out.splitlines() if line.strip()]
        if not remotes:
            note("remotes", "git remote", code, "reachable",
                 "no git remote: nothing off this machine holds this work")
            return "reachable", evidence
        note("remotes", "git remote", code, "ok", ", ".join(remotes))

        code, out = run_git(
            repo, ["log", "--branches", "--not", "--remotes", "--oneline"],
            timeout,
        )
        unpushed = [line for line in out.splitlines() if line.strip()]
        if unpushed:
            note("unpushed", "git log --branches --not --remotes --oneline",
                 code, "reachable",
                 "{0} commit(s) on no remote, first: {1}".format(
                     len(unpushed), unpushed[0].strip()))
            return "reachable", evidence
        note("unpushed", "git log --branches --not --remotes --oneline", code,
             "clean", "0 unpushed commits (local remote-tracking view)")

        # git branch -r reads the stale local cache and will happily claim a
        # branch is on a remote that never received it. Ask the remote itself.
        remote_shas = set()
        for remote in remotes:
            code, out = run_git(repo, ["remote", "get-url", remote], timeout)
            url = out.strip()
            if options["offline"] and not remote_is_local(url):
                raise GitUnknown({
                    "check": "ls-remote",
                    "command": "git ls-remote {0}".format(remote),
                    "exit_code": None, "result": "unknown",
                    "detail": "--offline: cannot contact remote {0} ({1})".format(
                        remote, url),
                })
            if url in remote_cache:
                shas = remote_cache[url]
            else:
                code, out = run_git(
                    repo, ["ls-remote", "--heads", "--tags", remote], timeout
                )
                shas = set()
                for line in out.splitlines():
                    parts = line.split("\t")
                    if parts and len(parts[0]) >= 7:
                        shas.add(parts[0].strip())
                remote_cache[url] = shas
            remote_shas |= shas
        note("ls-remote", "git ls-remote --heads --tags <each remote>", 0, "ok",
             "{0} ref(s) confirmed live on {1} remote(s)".format(
                 len(remote_shas), len(remotes)))
        if not remote_shas:
            note("ls-remote", "git ls-remote --heads --tags <each remote>", 0,
                 "reachable", "remote advertised no refs; nothing is confirmed")
            return "reachable", evidence

        code, out = run_git(
            repo,
            ["for-each-ref", "--format=%(objectname) %(refname:short)",
             "refs/heads"],
            timeout,
        )
        heads = []
        for line in out.splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2:
                heads.append((parts[1], parts[0]))
        code, out = run_git(repo, ["rev-parse", "HEAD"], timeout, allowed=(0, 128))
        head_sha = out.strip()
        if code == 0 and head_sha and head_sha not in [sha for _, sha in heads]:
            heads.append(("HEAD", head_sha))
        if not heads:
            note("branches", "git for-each-ref refs/heads", code, "reachable",
                 "no local branch and no HEAD commit to confirm")
            return "reachable", evidence

        # A head is pushed when nothing reachable from it is missing from what
        # the remote just advertised. One rev-list answers that for a head,
        # whatever the remote's ref count; --ignore-missing drops advertised
        # objects this checkout does not have, which only ever makes the
        # answer more conservative.
        exclusions = "".join("^{0}\n".format(s) for s in sorted(remote_shas))
        for name, sha in heads:
            if sha in remote_shas:
                continue
            code, out = run_git(
                repo, ["rev-list", "--count", "--ignore-missing", "--stdin"],
                timeout, stdin_data="{0}\n{1}".format(sha, exclusions),
            )
            try:
                ahead = int(out.strip() or "0")
            except ValueError:
                raise GitUnknown({
                    "check": "rev-list",
                    "command": "git rev-list --count --ignore-missing --stdin",
                    "exit_code": code, "result": "unknown",
                    "detail": "unparseable commit count: {0!r}".format(
                        out.strip()[:100]),
                })
            if ahead:
                note("branches", "git ls-remote + git rev-list --count", 0,
                     "reachable",
                     "branch {0} ({1}) has {2} commit(s) on no real "
                     "remote".format(name, sha[:12], ahead))
                return "reachable", evidence
        note("branches", "git ls-remote + git rev-list --count", 0, "clean",
             "all {0} local head(s) confirmed present on a real remote".format(
                 len(heads)))
    except GitUnknown as exc:
        evidence.append(exc.evidence)
        return "unknown", evidence
    return "unreachable", evidence


def scan_subtree(path):
    """One pass: apparent size, newest mtime, git checkouts, protected files.

    Any unreadable directory or entry is recorded as an error. A subtree we
    could not fully read is not a subtree we are willing to delete, so the
    caller turns errors into UNKNOWN.
    """
    stats = {
        "size": 0, "apparent_size": 0, "files": 0, "newest_mtime": 0.0,
        "checkouts": [], "protected_hits": [], "errors": [],
    }
    # A budget is about blocks on the disk, not about logical file lengths.
    # `git clone` from a local path hardlinks .git/objects, and a directory
    # full of local clones reads as more than twice its real size when those
    # links are counted once per name -- exactly the error that would make a
    # reclaim estimate optimistic. Count allocated blocks, and count a
    # multiply-linked inode once per candidate, the way du does.
    seen_inodes = set()

    def measure(info):
        if info.st_nlink > 1:
            key = (info.st_dev, info.st_ino)
            if key in seen_inodes:
                return
            seen_inodes.add(key)
        stats["size"] += info.st_blocks * 512
        stats["apparent_size"] += info.st_size

    try:
        top = os.lstat(path)
    except OSError as exc:
        stats["errors"].append("{0}: {1}".format(path, exc.strerror or exc))
        return stats
    stats["newest_mtime"] = top.st_mtime
    measure(top)
    if not stat.S_ISDIR(top.st_mode):
        stats["files"] = 1
        if os.path.basename(path) in GC_PROTECTED_NAMES:
            stats["protected_hits"].append(path)
        return stats
    pending = [path]
    while pending:
        current = pending.pop()
        try:
            entries = list(os.scandir(current))
        except OSError as exc:
            stats["errors"].append(
                "{0}: {1}".format(current, exc.strerror or exc))
            continue
        names = set()
        for entry in entries:
            names.add(entry.name)
            try:
                info = entry.stat(follow_symlinks=False)
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError as exc:
                stats["errors"].append(
                    "{0}: {1}".format(entry.path, exc.strerror or exc))
                continue
            measure(info)
            stats["files"] += 1
            if info.st_mtime > stats["newest_mtime"]:
                stats["newest_mtime"] = info.st_mtime
            if entry.name in GC_PROTECTED_NAMES:
                stats["protected_hits"].append(entry.path)
            if is_dir:
                pending.append(entry.path)
        if ".git" in names:
            stats["checkouts"].append(current)
    stats["checkouts"].sort()
    return stats


def protected_match(path, protected_roots, stats):
    real = os.path.realpath(path)
    for root in protected_roots:
        if real == root or path_within(real, root) or path_within(root, real):
            return "denylisted path: {0}".format(root)
    for name in GC_PROTECTED_NAMES:
        if name in path or name in real:
            return "path names a protected database: {0}".format(name)
    if stats is not None and stats["protected_hits"]:
        return "subtree contains a protected database: {0}".format(
            stats["protected_hits"][0])
    return None


def gc_decide(record, options, budget_state):
    """The single ordered decision ladder. First match wins.

    Returns (decision, rule_number, reason). `decision` is "collect" or "keep".
    """
    # Rule 1: the denylist is absolute and outranks every other signal,
    # including a candidate that is old, unreachable and over budget.
    if record["protected"]:
        return "keep", GC_RULE_PROTECTED, record["protected"]
    # Rule 2: git could not answer. Unknown is treated as reachable.
    if record["verdict"] == "unknown":
        return "keep", GC_RULE_UNKNOWN, record["verdict_reason"]
    # Rule 3: something that matters still points at this path.
    if record["verdict"] == "reachable":
        return "keep", GC_RULE_REACHABLE, record["verdict_reason"]
    # Rule 4: the age floor is a floor. Budget pressure does not lower it.
    if record["age_days"] < options["older_than"]:
        return "keep", GC_RULE_TOO_YOUNG, (
            "{0:.2f}d old, floor is {1:g}d".format(
                record["age_days"], options["older_than"]))
    # Rule 5: only now does the budget get a vote.
    budget = budget_state["budget"]
    if budget is None:
        return "keep", GC_RULE_DEFAULT, (
            "eligible, but no --budget is set so nothing triggers collection")
    if budget_state["projected"] <= budget:
        return "keep", GC_RULE_BUDGET, (
            "footprint {0} already within budget {1}".format(
                human_size(budget_state["projected"]), human_size(budget)))
    budget_state["projected"] -= record["size"]
    return "collect", GC_RULE_BUDGET, (
        "over budget: reclaiming {0} leaves {1} against budget {2}".format(
            human_size(record["size"]),
            human_size(budget_state["projected"]), human_size(budget)))


def gc_candidates(root, depth):
    """Collection units under a root: depth-1 children by default.

    A directory that is itself a git checkout is never split apart, whatever
    --depth says: a checkout is one unit or it is nothing.
    """
    found = []
    frontier = [(root, 0)]
    while frontier:
        current, level = frontier.pop(0)
        try:
            entries = sorted(os.scandir(current), key=lambda e: e.name)
        except OSError:
            continue
        if not entries and current != root:
            found.append(current)
            continue
        for entry in entries:
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                is_dir = False
            is_checkout = is_dir and os.path.lexists(
                os.path.join(entry.path, ".git"))
            if not is_dir or is_checkout or level + 1 >= depth:
                found.append(entry.path)
            else:
                frontier.append((entry.path, level + 1))
    return found


def gc_scan(options):
    """Build one receipt per candidate, then run the ladder oldest-first."""
    now = time.time()
    remote_cache = {}
    records = []
    errors = []
    queue = []
    for root in options["roots"]:
        if not os.path.isdir(root):
            errors.append("root is not a directory: {0}".format(root))
            continue
        for path in gc_candidates(root, options["depth"]):
            queue.append((root, path))
    # Verifying a large accumulation site is minutes of git calls. A scan that
    # says nothing for that long is indistinguishable from a hang.
    total_candidates = len(queue)
    for index, (root, path) in enumerate(queue, 1):
        if options["progress"]:
            sys.stderr.write("[{0}/{1}] {2}\n".format(
                index, total_candidates, path))
            sys.stderr.flush()
        record = {
            "path": path, "root": root, "decision": None, "rule": None,
            "rule_name": None, "reason": None, "protected": None,
            "size": 0, "size_human": "0B", "apparent_size": 0,
            "age_days": 0.0,
            "dir_age_days": 0.0, "files": 0, "checkouts": [],
            "verdict": "unknown", "verdict_reason": "", "evidence": [],
        }
        if os.path.islink(path):
            record["protected"] = None
            record["verdict"] = "reachable"
            record["verdict_reason"] = "symlink: not followed, not collected"
            record["evidence"] = [{
                "check": "symlink", "command": "os.path.islink",
                "exit_code": None, "result": "reachable",
                "detail": "candidate is a symlink",
            }]
            records.append(record)
            continue
        early = protected_match(path, options["protected"], None)
        if early:
            record["protected"] = early
            record["evidence"] = [{
                "check": "denylist", "command": "protected_match",
                "exit_code": None, "result": "protected", "detail": early,
            }]
            records.append(record)
            continue
        stats = scan_subtree(path)
        record["size"] = stats["size"]
        record["size_human"] = human_size(stats["size"])
        record["apparent_size"] = stats["apparent_size"]
        record["files"] = stats["files"]
        record["checkouts"] = stats["checkouts"]
        record["age_days"] = max(0.0, (now - stats["newest_mtime"]) / 86400.0)
        try:
            record["dir_age_days"] = max(
                0.0, (now - os.path.getmtime(path)) / 86400.0)
        except OSError:
            record["dir_age_days"] = record["age_days"]
        hit = protected_match(path, options["protected"], stats)
        if hit:
            record["protected"] = hit
            record["evidence"] = [{
                "check": "denylist", "command": "protected_match",
                "exit_code": None, "result": "protected", "detail": hit,
            }]
            records.append(record)
            continue
        if stats["errors"]:
            record["verdict"] = "unknown"
            record["verdict_reason"] = (
                "{0} path(s) could not be read, first: {1}".format(
                    len(stats["errors"]), stats["errors"][0]))
            record["evidence"] = [{
                "check": "scan", "command": "os.scandir", "exit_code": None,
                "result": "unknown", "detail": detail,
            } for detail in stats["errors"][:5]]
            records.append(record)
            continue
        if not stats["checkouts"]:
            record["verdict"] = "unreachable"
            record["verdict_reason"] = (
                "no git checkout in subtree: age and budget only")
            record["evidence"] = [{
                "check": "git-checkouts", "command": "scan for .git",
                "exit_code": None, "result": "unreachable",
                "detail": "0 git checkouts in {0} file(s)".format(
                    stats["files"]),
            }]
            records.append(record)
            continue
        if len(stats["checkouts"]) > options["max_checkouts"]:
            record["verdict"] = "unknown"
            record["verdict_reason"] = (
                "{0} git checkouts exceeds --max-checkouts {1}".format(
                    len(stats["checkouts"]), options["max_checkouts"]))
            record["evidence"] = [{
                "check": "git-checkouts", "command": "scan for .git",
                "exit_code": None, "result": "unknown",
                "detail": record["verdict_reason"],
            }]
            records.append(record)
            continue
        verdicts = []
        for repo in stats["checkouts"]:
            verdict, evidence = checkout_reachability(
                repo, options, remote_cache)
            verdicts.append(verdict)
            for item in evidence:
                item = dict(item)
                item["repo"] = repo
                record["evidence"].append(item)
            if verdict == "unknown":
                break
        if "unknown" in verdicts:
            record["verdict"] = "unknown"
            record["verdict_reason"] = (
                "git could not answer for {0}".format(
                    stats["checkouts"][len(verdicts) - 1]))
        elif "reachable" in verdicts:
            record["verdict"] = "reachable"
            reached = stats["checkouts"][verdicts.index("reachable")]
            record["verdict_reason"] = (
                "still reachable: {0}".format(reached))
        else:
            record["verdict"] = "unreachable"
            record["verdict_reason"] = (
                "{0} checkout(s) clean, pushed and confirmed on a "
                "remote".format(len(stats["checkouts"])))
        records.append(record)

    total = sum(r["size"] for r in records)
    budget_state = {"budget": options["budget"], "projected": total}
    # Oldest first: the ladder only ever spends budget on the coldest bytes.
    for record in sorted(records, key=lambda r: -r["age_days"]):
        decision, rule, reason = gc_decide(record, options, budget_state)
        record["decision"] = decision
        record["rule"] = rule
        record["rule_name"] = GC_RULE_NAMES[rule]
        record["reason"] = reason
    records.sort(key=lambda r: (r["decision"] != "collect", -r["size"]))
    return records, errors, total


def gc_remove(path):
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
    else:
        shutil.rmtree(path)


def cmd_gc(args):
    if args.collect and args.dry_run:
        sys.stderr.write(
            "agent-trash: --dry-run and --collect are mutually exclusive\n")
        return 1
    roots = []
    for chunk in args.roots:
        for piece in chunk.split(","):
            piece = piece.strip()
            if piece:
                roots.append(os.path.realpath(os.path.expanduser(piece)))
    if not roots:
        roots = [os.path.realpath(TRASH_DIR)]
    home = os.path.realpath(os.path.expanduser("~"))
    for root in roots:
        if root == os.path.realpath(os.sep) or root == home:
            sys.stderr.write(
                "agent-trash: refusing to scan {0} as a root; name the "
                "accumulation directories explicitly\n".format(root))
            return 1

    protected = [os.path.realpath(os.path.expanduser(p))
                 for p in GC_PROTECTED_DEFAULT]
    extra = list(args.protect or [])
    env_protect = os.environ.get("AGENT_TRASH_PROTECT", "")
    if env_protect:
        extra.extend(env_protect.replace(":", ",").split(","))
    for chunk in extra:
        for piece in str(chunk).split(","):
            piece = piece.strip()
            if piece:
                protected.append(os.path.realpath(os.path.expanduser(piece)))

    options = {
        "roots": roots,
        "protected": sorted(set(protected)),
        "older_than": args.older_than,
        "budget": args.budget,
        "depth": max(1, args.depth),
        "git_timeout": args.git_timeout,
        "offline": args.offline,
        "max_checkouts": args.max_checkouts,
        "progress": args.progress,
    }
    records, errors, total = gc_scan(options)

    collecting = bool(args.collect)
    reclaimed = 0
    for record in records:
        record["collected"] = False
        if record["decision"] != "collect":
            continue
        if not collecting:
            continue
        guard = protected_match(record["path"], options["protected"], None)
        if guard:  # belt and braces: re-check rule 1 at the moment of deletion
            record["decision"] = "keep"
            record["rule"] = GC_RULE_PROTECTED
            record["rule_name"] = GC_RULE_NAMES[GC_RULE_PROTECTED]
            record["reason"] = guard
            continue
        try:
            gc_remove(record["path"])
            record["collected"] = True
            reclaimed += record["size"]
        except OSError as exc:
            record["collected"] = False
            record["error"] = "{0}: {1}".format(
                record["path"], exc.strerror or exc)
            errors.append(record["error"])

    collect_bytes = sum(r["size"] for r in records if r["decision"] == "collect")
    by_rule = {}
    for record in records:
        if record["decision"] == "collect":
            continue
        by_rule[record["rule_name"]] = by_rule.get(record["rule_name"], 0) + 1
    report = {
        "tool": "agent-trash",
        "version": VERSION,
        "command": "gc",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "dry_run": not collecting,
        "roots": roots,
        "protected": options["protected"],
        "older_than_days": options["older_than"],
        "budget_bytes": options["budget"],
        "depth": options["depth"],
        "offline": options["offline"],
        "rule_ladder": [
            "1 protected", "2 unknown", "3 reachable",
            "4 too-young", "5 budget", "6 default",
        ],
        "totals": {
            "candidates": len(records),
            "scanned_bytes": total,
            "collect_candidates": sum(
                1 for r in records if r["decision"] == "collect"),
            "collect_bytes": collect_bytes,
            "reclaimed_bytes": reclaimed,
            "kept_bytes": total - collect_bytes,
            "kept_by_rule": by_rule,
        },
        "errors": errors,
        "entries": records,
    }
    if args.receipt:
        try:
            with open(os.path.expanduser(args.receipt), "a") as f:
                f.write(json.dumps(report) + "\n")
        except OSError as exc:
            sys.stderr.write(
                "agent-trash: could not write receipt: {0}\n".format(exc))

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    mode = "COLLECT" if collecting else "dry run"
    print("agent-trash gc ({0})".format(mode))
    print("roots:     {0}".format(", ".join(roots)))
    print("budget:    {0}   age floor: {1:g}d   depth: {2}".format(
        human_size(options["budget"]) if options["budget"] is not None
        else "unset (rule 5 cannot fire)",
        options["older_than"], options["depth"]))
    print("")
    print("{0:8}  {1:>8}  {2:>8}  {3:12} {4:10} {5}".format(
        "DECISION", "SIZE", "AGE", "VERDICT", "RULE", "PATH"))
    for record in records:
        print("{0:8}  {1:>8}  {2:>7.1f}d  {3:12} {4:<10} {5}".format(
            record["decision"], record["size_human"], record["age_days"],
            record["verdict"], "{0} {1}".format(
                record["rule"], record["rule_name"]),
            record["path"]))
        print("          why: {0}".format(record["reason"]))
        for item in record["evidence"][:args.evidence_lines]:
            print("          evidence: {0} -> {1}: {2}".format(
                item.get("command", item.get("check")), item.get("result"),
                item.get("detail", "")))
    print("")
    print("scanned  {0} candidate(s), {1}".format(len(records),
                                                  human_size(total)))
    print("collect  {0} candidate(s), {1}{2}".format(
        report["totals"]["collect_candidates"], human_size(collect_bytes),
        "" if collecting else "   (dry run: nothing was deleted)"))
    if collecting:
        print("reclaimed {0}".format(human_size(reclaimed)))
    if by_rule:
        print("keep     " + ", ".join(
            "{0}={1}".format(name, count)
            for name, count in sorted(by_rule.items())))
    for message in errors:
        sys.stderr.write("agent-trash: {0}\n".format(message))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-trash", description=__doc__)
    parser.add_argument(
        "--version", action="version", version="agent-trash {0}".format(VERSION)
    )
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

    p_gc = sub.add_parser(
        "gc",
        help="report, and optionally reclaim, unreachable accumulated storage",
        description="Budget decides WHEN to collect; reachability decides WHAT "
                    "may be collected. Decision ladder, first match wins: "
                    "1 protected, 2 git-state-unknown, 3 reachable, "
                    "4 younger than the age floor, 5 over budget (collect "
                    "oldest-first), 6 keep.",
    )
    p_gc.add_argument("--roots", action="append", default=[], metavar="PATH",
                      help="comma-separated scan roots (default: the trash dir); "
                           "repeatable")
    p_gc.add_argument("--budget", type=size_arg, default=None, metavar="SIZE",
                      help="total footprint to stay under, e.g. 5G; without it "
                           "rule 5 never fires and nothing is collected")
    p_gc.add_argument("--older-than", type=float, default=7.0, metavar="DAYS",
                      help="age floor; never collect anything newer, whatever "
                           "the budget says (default 7)")
    p_gc.add_argument("--depth", type=int, default=1, metavar="N",
                      help="how many levels below a root a collection unit may "
                           "sit (default 1); a git checkout is never split")
    p_gc.add_argument("--protect", action="append", default=[], metavar="PATH",
                      help="extra never-collect paths; adds to the built-in "
                           "denylist, which cannot be removed")
    p_gc.add_argument("--dry-run", action="store_true", default=False,
                      help="explicitly report only; this is already the default")
    p_gc.add_argument("--collect", action="store_true",
                      help="actually delete what rule 5 selected")
    p_gc.add_argument("--json", action="store_true",
                      help="emit the full machine-readable receipt")
    p_gc.add_argument("--receipt", metavar="PATH",
                      help="append the run's JSON receipt to this file")
    p_gc.add_argument("--offline", action="store_true",
                      help="treat any non-local remote as unverifiable, which "
                           "makes its checkout UNKNOWN and therefore kept")
    p_gc.add_argument("--git-timeout", type=float, default=30.0, metavar="SECONDS",
                      help="per git call; a timeout is UNKNOWN, never clean")
    p_gc.add_argument("--max-checkouts", type=int, default=50, metavar="N",
                      help="a candidate holding more checkouts than this is "
                           "UNKNOWN rather than slowly verified (default 50)")
    p_gc.add_argument("--evidence-lines", type=int, default=2, metavar="N",
                      help="evidence lines to print per candidate (default 2)")
    p_gc.add_argument("--progress", action="store_true",
                      help="name each candidate on stderr as it is verified; a "
                           "large root is minutes of git calls, and a silent "
                           "scan looks like a hang")
    p_gc.set_defaults(func=cmd_gc)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
