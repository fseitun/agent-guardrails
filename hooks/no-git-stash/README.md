# no-git-stash

A Claude Code `PreToolUse` hook that blocks `git stash` (except read-only `stash list` and `stash show`).

Why: the stash belongs to the repository, not to the worktree. With several agents in parallel worktrees, one agent's stash can be popped by another. Parallel subagents ran it 80 times in two days, even though the project rules forbade it: a written rule alone did not hold.

The block message tells the agent what to do instead: read the base with `git show origin/<base>:<path>`, use a second worktree, or commit a `wip`. It ignores heredoc text (a commit message that mentions stash) and fails open on anything it cannot parse.

## Install

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/no-git-stash.py" }] }
    ]
  }
}
```
