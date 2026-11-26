#!/usr/bin/env python3
"""PreToolUse(Bash) guard: pull right before a push, and only then.

Blocks a `git push` of a feature branch when the commit being pushed does not
contain origin/<base> (develop, or main where develop does not exist) or
origin/<branch> itself, checked right after a fetch. Merge, never rebase.

Set PULL_BEFORE_PUSH_REMOTE_MATCH (e.g. "github.com/my-org/") to limit it to
repos whose origin URL contains that text; unset, it checks every repo.

Fails open (exit 0) on anything it cannot parse or reach, so a network blip
never wedges a session. Exit 2 blocks the call and hands stderr to Claude.
"""
import json
import os
import re
import shlex
import subprocess
import sys

BASE_BRANCHES = {"develop", "main", "master"}


def git(repo, *args, timeout=30):
    return subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def push_segments(command):
    # Split on shell separators; keep the cwd implied by earlier `cd X` segments.
    parts = re.split(r"\s*(?:&&|\|\||\||;|\n)\s*", command)
    cd = None
    for part in parts:
        try:
            tokens = shlex.split(part)
        except ValueError:
            continue
        if len(tokens) >= 2 and tokens[0] == "cd":
            cd = tokens[1]
            continue
        if "git" not in tokens:
            continue
        i = tokens.index("git")
        rest = tokens[i + 1 :]
        repo = None
        while len(rest) >= 2 and rest[0] == "-C":
            repo = rest[1]
            rest = rest[2:]
        if rest and rest[0] == "push":
            yield (repo or cd), rest[1:]


def parse_push(args):
    if any(a in ("--delete", "-d", "--tags", "--dry-run", "-n", "--mirror") for a in args):
        return None
    positional = [a for a in args if not a.startswith("-") and not re.match(r"^\d*[<>]", a)]
    refspecs = positional[1:]
    if not refspecs:
        return "HEAD", None
    spec = refspecs[-1].lstrip("+")
    if spec.startswith(":"):
        return None
    if ":" in spec:
        src, dst = spec.split(":", 1)
    else:
        src = dst = spec
    return src or "HEAD", dst.replace("refs/heads/", "")


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not re.search(r"\bgit\b.*\bpush\b", command):
        return 0
    cwd = payload.get("cwd") or os.getcwd()

    problems = []
    for repo_arg, args in push_segments(command):
        parsed = parse_push(args)
        if not parsed:
            continue
        src, dst = parsed
        repo = os.path.expanduser(repo_arg) if repo_arg else cwd
        if not os.path.isabs(repo):
            repo = os.path.join(cwd, repo)
        try:
            url = git(repo, "remote", "get-url", "origin").stdout.strip()
            match = os.environ.get("PULL_BEFORE_PUSH_REMOTE_MATCH", "")
            if not url or (match and match not in url):
                continue
            if dst is None:
                dst = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
            if not dst or dst == "HEAD" or dst in BASE_BRANCHES or dst.startswith("release/"):
                continue
            if git(repo, "fetch", "-q", "origin", timeout=45).returncode != 0:
                continue
            base = "develop" if git(repo, "rev-parse", "-q", "--verify", "origin/develop").returncode == 0 else "main"
            sha = git(repo, "rev-parse", "-q", "--verify", f"{src}^{{commit}}").stdout.strip()
            if not sha:
                continue
            missing = []
            for ref in (f"origin/{dst}", f"origin/{base}"):
                if git(repo, "rev-parse", "-q", "--verify", ref).returncode != 0:
                    continue
                if git(repo, "merge-base", "--is-ancestor", ref, sha).returncode != 0:
                    n = git(repo, "rev-list", "--count", f"{sha}..{ref}").stdout.strip()
                    missing.append(f"{n} commit(s) from {ref}")
            if missing:
                refs = " ".join(f"origin/{r}" for r in (dst, base))
                problems.append(
                    f"- {repo}: pushing {src} -> {dst} lacks " + " and ".join(missing) + ".\n"
                    f"  Fix: git -C {repo} fetch origin && git -C {repo} merge {refs}"
                    " (merge, never rebase), resolve, re-run your checks, then push."
                )
        except (subprocess.TimeoutExpired, OSError):
            continue

    if problems:
        sys.stderr.write(
            "Blocked by the pull-before-push hook: pull right before a push, and only then.\n"
            + "\n".join(problems)
            + "\nThe check runs before the whole command: if this same command commits a merge first,"
            " commit in one call and push in the next.\n"
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
