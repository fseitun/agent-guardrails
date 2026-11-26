# stale-agent-procs

A Claude Code skill. Ask "what did agents leave running?" or "port 3000 is already in use", and it lists what agent sessions left behind, then cleans up only what you approve:

- process groups (dev servers, test runners, headless Chromium, Gradle daemons, Metro) whose session is gone or idle, with age, RAM, CPU, cwd, ports and who is connected
- docker compose stacks running with nobody connected

## Install

```bash
cp -r stale-agent-procs ~/.claude/skills/
```

List compose projects it must never touch in `protected-stacks`, one per line.

## Safety

- It only kills groups that nothing is connected to.
- `--down` (which deletes volumes) only accepts throwaway e2e stacks; any other stack gets `--stop`, which keeps its data.
- It runs by hand too: `~/.claude/skills/stale-agent-procs/stale-procs.sh` lists everything and changes nothing.
