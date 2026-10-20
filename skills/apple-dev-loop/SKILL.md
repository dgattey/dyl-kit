---
name: apple-dev-loop
description: Build, relaunch, screenshot and check a DylKit app on macOS or the iOS Simulator without touching the installed release or stealing focus. Use for any local build, visual check, or light/dark comparison.
---

# Apple dev loop

Every command runs from the app repo through `./run dev …` (it builds `devkit` and finds `DylApp.toml`).

| Task | Command |
|---|---|
| Build `build/<App>.app` (ad-hoc signed, commit-count build number) | `./run dev build` |
| Rebuild and reopen behind the frontmost app | `./run dev relaunch` |
| Screenshot the main window | `./run dev capture --appearance dark` |
| iOS Simulator, headless, with a screenshot | `./run dev ios --run --capture` |
| Lint tiers 1–3 | `./run dev checks` |
| Checks, then build and test everything | `./run dev verify` |

## Hard rules

- Only `build/` is ours. Never copy into, launch, kill or overwrite `/Applications/<App>.app` unless Dylan asks for a one-time install. `relaunch` only stops the process whose path is under `build/`.
- Never steal focus: `open -g`, `screencapture -l <window>`, headless `simctl`. No `NSApp.activate`, AppleScript `activate`, or `open -a Simulator`.
- Never change the system appearance. Pass `--appearance light|dark`; the app reads `<PREFIX>_APPEARANCE` through `LaunchOverrides` and sets its own appearance, and leaves it `nil` on a normal run.
- Pick the starting screen with `--initial-view <name>` and the size with `--window-size 1280x800` instead of clicking through the UI.
- Captures go to `build/captures/`. When sharing one, copy it to a new, uniquely versioned filename so image caches never show a stale render.

## When a capture comes back wrong

- A blank or black PNG means Screen Recording isn't granted to the process running `devkit`; say so instead of retrying.
- "No window" means the app hasn't drawn yet; raise `--settle`.
- The iOS build uses the `[ios]` table of `DylApp.toml` for the bundle ID and simulator.
