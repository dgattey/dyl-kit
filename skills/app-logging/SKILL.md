---
name: app-logging
description: Logging in DylKit apps with os.Logger — subsystems, categories, privacy, and reading logs during a dev loop. Use when adding diagnostics or chasing a bug through logs.
---

# App logging

- `Logger(subsystem: Bundle.main.bundleIdentifier ?? "<App>", category: "<area>")`, one per area, as a `static let`. No `print` in app targets (`print_in_app`).
- Interpolate with privacy: `\(value, privacy: .public)` only for non-identifying values; tokens, names, emails and IPs stay private.
- Levels: `debug` for chatter, `info` for state changes worth keeping, `error` for failures someone should look at, `fault` for broken invariants.
- Decode failures log through `JSONDecoder.decodeOrLog` from `DylCore` rather than disappearing (`swallowed_decode`).
- High-volume diagnostics (network traces) go through one ordered consumer and stay off by default.

Read a dev build's logs without Console.app focus:

```bash
log stream --level debug --predicate 'subsystem == "<bundle id>"'
log show --last 5m --predicate 'subsystem == "<bundle id>" AND category == "Sparkle"'
```
