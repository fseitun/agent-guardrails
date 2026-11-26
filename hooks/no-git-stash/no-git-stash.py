#!/usr/bin/env python3
"""PreToolUse(Bash) guard: agents never run `git stash`.

The stash stack belongs to the repository, not to the worktree, so a `git stash` in one
worktree is visible to (and can be popped by) every other session working on that repo.
Parallel subagents ran it 80 times in two days to compare `tsc` output with and without
their edits, although the project's CLAUDE.md forbade it: the written rule alone did not hold.

Read-only forms (`stash list`, `stash show`) pass. Everything else is blocked with what to do
instead. Fails open (exit 0) on anything it cannot parse. Exit 2 blocks the call and hands
stderr to Claude.
"""
import json
import re
import shlex
import sys

READ_ONLY = {"list", "show"}


def stash_calls(command):
    # Heredoc bodies are data (a commit message that mentions stash), not commands.
    command = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?\n\2\b", " ", command, flags=re.S)
    for part in re.split(r"\s*(?:&&|\|\||\||;|\n)\s*", command):
        try:
            tokens = shlex.split(part)
        except ValueError:
            continue
        # skip leading VAR=value assignments and wrappers such as `timeout 30`
        while tokens and (re.match(r"^\w+=", tokens[0]) or tokens[0] in ("command", "exec", "time", "timeout")):
            tokens = tokens[1:]
            while tokens and re.match(r"^(-\S+|\d+[smhd]?)$", tokens[0]):  # timeout's own flags and duration
                tokens = tokens[1:]
        if not tokens or tokens[0] != "git":
            continue
        rest = tokens[1:]
        while len(rest) >= 2 and rest[0] in ("-C", "-c", "--git-dir", "--work-tree"):
            rest = rest[2:]
        if rest and rest[0] == "stash":
            sub = next((a for a in rest[1:] if not a.startswith("-")), "push")
            if sub not in READ_ONLY:
                yield part.strip()


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if "stash" not in command:
        return 0
    hits = list(stash_calls(command))
    if not hits:
        return 0
    sys.stderr.write(
        "Blocked by the no-git-stash hook: the stash stack is shared by every worktree of the repo, so a stash"
        " here can be popped by another session.\n"
        + "".join(f"- {h[:160]}\n" for h in hits[:3])
        + "Instead: to compare with the base, read it from git (`git diff origin/<base> -- <path>`,"
        " `git show origin/<base>:<path>`) or check the base out in a second worktree"
        " (`git worktree add --detach /tmp/wt-base origin/<base>`) and run the"
        " command there. To set work aside, commit it on the branch (`git commit -m wip`).\n"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 - a broken guard must never block a session
        sys.exit(0)
