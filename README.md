# agent-guardrails

Small guardrails I run around Claude Code agents on my own machine. When several agents work at once, each one only sees its own task. These tools look at the whole machine.

Linux only. No dependencies beyond Python 3 and Bash.

| Piece | What it does |
|---|---|
| [`hooks/agent-load-gate`](hooks/agent-load-gate) | A `PreToolUse` hook that holds back heavy test, build and lint runs when the machine is low on RAM or already running two of them. The agent gets a reason it can act on: wait, then run one step at a time. |
| [`skills/stale-agent-procs`](skills/stale-agent-procs) | A skill that finds what agent sessions left running (dev servers, test runners, headless Chromium, Gradle daemons, idle docker compose stacks) and cleans up only what nobody is using. |

Related: [claude-account-guard](https://github.com/fseitun/claude-account-guard) warns or blocks when you're signed into the wrong Claude account for a project.

## Why

- **The load gate:** one agent job ran five test groups in parallel (jest, eslint and tsc, two copies each). It took 28 of 30 GB of RAM and froze the desktop. Now heavy runs queue instead.
- **Stale processes:** agents start things and don't clean up. Ports stay taken, fans spin, and nobody remembers which session started what.

## What they refuse to do

- The load gate fails open: if it errors, the command runs. It never blocks cheap commands (`--version`, `--help`, `git`, `ls`), and it ignores heredoc file contents.
- The stale-process skill only kills process groups that have no clients. It never deletes a docker volume unless the stack is a throwaway e2e stack, and it never touches stacks listed in `protected-stacks`.

## License

MIT
