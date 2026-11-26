# narrow-send-wrapper (pattern)

How to let an agent read a messaging tool freely while every send needs your OK and shows exactly what will go out. The example uses [wacli](https://github.com/openclaw/wacli) (WhatsApp CLI), but the pattern works for any CLI that can both read and send.

1. **A read-only default.** `wacli` here is a shim that forces read-only mode, then calls the real binary. Anything that finds `wacli` on PATH, agents included, can search and read but can't send.
2. **One narrow send command.** `wacli-send <recipient> <text>` takes exactly two arguments, with no flags passed through. The recipient must be a phone number or an ID, never a name the tool would have to resolve, so the approval prompt shows exactly who gets what.
3. **An approval rule.** Claude Code asks before every call:

```json
{ "permissions": { "ask": ["Bash(*wacli-send*)"] } }
```

Why: a broad "send" permission makes the approval prompt hard to read (flags, lookups, scripts). A narrow command turns each approval into one line you can check at a glance.
