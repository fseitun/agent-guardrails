# statusline

A Claude Code status line: model, effort, context used, and the 5-hour and 7-day rate limits, each with time to reset. Green, then amber at 70%, red at 90%.

```
Opus | high | 42% | 5h: 75% (1.3h) | 7d: 31% (4.2d)
```

Why: running several agents at once burns through limits without you noticing. This keeps the pressure in view, next to the load gate that holds runs back.

```json
{ "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }
```

Needs `jq`.
