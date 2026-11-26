# agent-guardrails

Small guardrails I run around Claude Code agents on my own machine. When several agents work at once, each one only sees its own task. These tools look at the whole machine.

Linux only. No dependencies beyond Python 3 and Bash (plus `git`, `gh` and `jq` where noted).

| Piece | What it does |
|---|---|
| [`hooks/agent-load-gate`](hooks/agent-load-gate) | A `PreToolUse` hook that holds back heavy test, build and lint runs when the machine is low on RAM or already running two of them. The agent gets a reason it can act on: wait, then run one step at a time. |
| [`skills/stale-agent-procs`](skills/stale-agent-procs) | A skill that finds what agent sessions left running (dev servers, test runners, headless Chromium, Gradle daemons, idle docker compose stacks) and cleans up only what nobody is using. |
| [`hooks/no-git-stash`](hooks/no-git-stash) | Blocks `git stash`: the stash is shared across worktrees, so one agent's stash can be popped by another. |
| [`hooks/pull-before-push`](hooks/pull-before-push) | Blocks pushing a feature branch that's behind its remote or the base branch, and gives the exact merge command. |
| [`scripts/reap-worktrees`](scripts/reap-worktrees) | Removes worktrees only when their PR is merged, they're clean, nothing runs inside them and they've been idle for 24 h. A dry run by default. |
| [`statusline`](statusline) | Status line with context used and the 5 h / 7 d rate limits, so you see the pressure before you hit it. |
| [`patterns/narrow-send-wrapper`](patterns/narrow-send-wrapper) | Read freely, send narrowly: a read-only default plus one tiny send command, so every approval prompt shows the exact recipient and text. |

Related: [claude-account-guard](https://github.com/fseitun/claude-account-guard) warns or blocks when you're signed into the wrong Claude account for a project.

## Why

- **The load gate:** one agent job ran five test groups in parallel (jest, eslint and tsc, two copies each). It took 28 of 30 GB of RAM and froze the desktop. Now heavy runs queue instead.
- **Stale processes:** agents start things and don't clean up. Ports stay taken, fans spin, and nobody remembers which session started what.
- **Git hooks:** a rule written in CLAUDE.md is a request; a hook is a guarantee. Each of these replaced a rule that agents kept breaking.

## What they refuse to do

- The load gate fails open: if it errors, the command runs. It never blocks cheap commands (`--version`, `--help`, `git`, `ls`), and it ignores heredoc file contents.
- The git hooks fail open too, and they block only the risky form: `stash list` still works, and pushes to base branches pass through.
- reap-worktrees changes nothing without `--apply`, and never uses `--force`.
- The stale-process skill only kills process groups that have no clients. It never deletes a docker volume unless the stack is a throwaway e2e stack, and it never touches stacks listed in `protected-stacks`.

## License

MIT
