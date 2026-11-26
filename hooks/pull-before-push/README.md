# pull-before-push

A Claude Code `PreToolUse` hook. Before an agent pushes a feature branch, it fetches and blocks the push if the commit being pushed is missing anything from `origin/<branch>` or the base branch (`develop`, else `main`). The message gives the exact merge command (merge, never rebase).

Why: agents push stale branches, and then CI and reviewers spend time on conflicts that a fetch would have caught. Pushes to `main`, `develop`, `master` or `release/*`, deletes, tags and dry runs pass through. If it cannot fetch, it lets the push through.

Set `PULL_BEFORE_PUSH_REMOTE_MATCH` (e.g. `github.com/my-org/`) to limit it to some repos.

## Install

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/pull-before-push.py" }] }
    ]
  }
}
```
