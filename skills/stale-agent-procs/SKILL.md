---
name: stale-agent-procs
description: Find and kill what Claude Code sessions left running — node/dev-server processes (vite, jest, nest, npm run dev/start:dev, tsx, esbuild, bun, Metro/Expo), Playwright headless Chromium, Gradle/Kotlin daemons, adb — and docker compose stacks nobody is using (leftover e2e stacks, idle dev stacks). Use when the user says they have stale, leftover, orphaned, zombie, rogue or runaway processes or containers, asks what agents left running, wonders why RAM/CPU/fans are pegged, hits EADDRINUSE or "port already in use", or asks to clean up dev servers or docker. Linux only.
---

# Stale agent processes and docker stacks

Long agent sessions start dev servers, watchers, test runners, build daemons and
throwaway compose stacks. When the session ends they survive — invisible, still holding
ports and hundreds of MB each.

## Use it

```bash
~/.claude/skills/stale-agent-procs/stale-procs.sh          # list
~/.claude/skills/stale-agent-procs/stale-procs.sh --all    # also what is in use
```

The listing has up to three parts:

- **Stale** — process groups whose session is gone.
- **Idle** — groups of a session that is still open but finished (job `done`/`stopped`)
  or has been waiting for 15+ minutes.
- **Docker compose stacks** — `[e2e]` stacks (project name contains `e2e`) and `[dev]`
  stacks that are running with nobody connected.

Each group shows its kind, age, total RSS, CPU right now, the cwd and command of the
real process (not the wrapper shell), the ports it listens on and who is connected.

```bash
stale-procs.sh --kill 317999 365691     # named groups, root + descendants
stale-procs.sh --kill-all               # every stale [node] [metro] [playwright] group with no clients
stale-procs.sh --down myapp-e2e-1234    # e2e stack: containers, networks AND volumes
stale-procs.sh --stop myapp-api         # any stack: stop containers, keep data
```

Kills are SIGTERM, then SIGKILL for anything still alive after 3s.

## Rules

- **Always list first, then ask.** Show the user the groups and stacks and let them
  pick. Never run `--kill-all` off your own bat, and never act on something the user
  did not name.
- **A refusal is information for the user, not an obstacle.** The script refuses when
  the owning session is busy or something is connected (`2 clients: adb(1449148)`).
  Relay the reason. Add `--force` only after the user has seen it and said yes.
- `--kill-all` only takes stale `[node]`, `[metro]` and `[playwright]` groups. Everything
  else is by explicit pid, after the user confirms:
  - `[gradle]` `[kotlin]` `[adb]` are daemons that later sessions pick up and reuse. One
    started by a dead session may be serving a live one right now.
  - `[other]` is anything else: leftover shells, `gcloud sql` / ssh tunnels, python
    watchers. Killing a bastion tunnel mid-query is not recoverable.
  - `[claude]` is a nested Claude session.
- **Idle is not stale.** The session can still be resumed and may want its server. Offer
  idle groups separately and say which session they belong to.
- **`--down` deletes data.** It only accepts e2e stacks. For a `[dev]` stack offer
  `--stop`; "no clients" is one instant's snapshot, so ask before stopping one.
- A group whose cwd is a `.claude/worktrees/` path is almost certainly dead work; one
  in a main checkout may still be the user's own server.

## How it decides

**Which processes.** Anything with `CLAUDECODE=1` in `/proc/<pid>/environ` was spawned
from an agent shell. A group is the topmost such process plus its descendants.

**Whose they are.** `<config>/sessions/<pid>.json` is Claude's own record of running
sessions (session id, pid, process start time, busy/idle, name, job). The group's
`CLAUDE_CODE_SESSION_ID` and `CLAUDE_CONFIG_DIR` are looked up there; an entry counts
only while that pid is alive with the recorded start time, so a recycled pid does not
keep a dead session alive.

A session missing from the registry still counts as running while the `claude` process
that spawned the group (`CLAUDE_PID`) is alive and older than the group. Only when
both the registry and that process are gone is a group stale.

Being reparented to `systemd --user` proves nothing: background jobs' processes and
every Gradle daemon are reparented while their session is busy.

If the session running the script is itself missing from the registry, the registry
format has probably changed. The listing says so and `--kill-all` refuses.

**In use.** A group's clients are the TCP connections into its listening ports from
outside the group — a browser tab on a vite server, an `adb shell` on the adb server,
a Gradle client on its daemon.

**Docker.** Stacks are compose projects. One whose working directory is inside a
session's job directory belongs to that session and is hidden while it is busy. Clients
are this machine's processes connected to the published ports.

`protected-stacks`, next to the script, holds compose project globs that are never
listed and never touched.

## Limits

- Never lists or kills the processes of the session that runs it.
- Client counts are a snapshot. For docker they miss container-to-container traffic and
  connections from other machines, so a stack used only by another container looks idle.
- An e2e stack started from a main checkout has no known owner; go by its age and clients.
- Only compose stacks. Plain `docker run` containers, unlabelled volumes and build cache
  are not covered — `docker system df` shows those.
