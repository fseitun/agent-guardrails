# agent-load-gate

A Claude Code `PreToolUse` hook for `Bash`. Before a heavy command starts (jest, vitest, eslint, tsc, playwright, cypress, gradle, webpack, `npm test`, `npm run build`, `npm ci` and the like), it checks the whole machine and denies the command when:

- free RAM (`MemAvailable`) is under 8 GB, or
- 2 heavy runs are already going. That counts live processes plus launches it allowed in the last 20 seconds, so a burst of subagents can't all slip through.

The denial tells the agent what to do: don't retry right away, wait until `agent-load-gate status` exits 0, then run heavy steps one at a time with jest/vitest capped at `--maxWorkers=2`.

## Install

```bash
cp agent-load-gate ~/.local/bin/ && chmod +x ~/.local/bin/agent-load-gate
```

Add it to `~/.claude/settings.json` (and to any other Claude Code config home you use):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/agent-load-gate" }] }
    ]
  }
}
```

## Use

```bash
agent-load-gate status   # free RAM and heavy runs; exit 0 = a new heavy run would be allowed
```

- **Tune:** `AGENT_LOAD_GATE_MIN_FREE_GB` (default 8) and `AGENT_LOAD_GATE_MAX_RUNS` (default 2).
- **Log:** decisions go to `$XDG_RUNTIME_DIR/agent-load-gate/log`.
- **Turn off:** use `/hooks`, or remove the entry from `settings.json`.
