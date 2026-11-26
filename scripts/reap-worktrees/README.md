# reap-worktrees

Removes git worktrees whose work is done. Claude Code cleans up only worktrees it made itself, so the ones agents add by hand with `git worktree add` pile up.

A worktree is removed only when **all** of these hold:
- its PR is merged and nothing was committed after the merge (or it's a detached HEAD already in the default branch)
- it has no uncommitted or untracked files, and it isn't locked
- no running process has its working directory inside it
- it has been untouched for 24 hours (`IDLE_HOURS`)

```bash
reap-worktrees.sh ~/code/my-repo            # dry run: REAP or KEEP, with the reason
reap-worktrees.sh --apply ~/code/my-repo    # remove the REAP ones (never --force)
reap-worktrees.sh --apply --throttle 6 ~/code/a ~/code/b   # at most once every 6 h, e.g. from a SessionStart hook
```

Needs `git`, `gh` (signed in) and `jq`. Removals are logged under `~/.local/state/reap-worktrees/`.
