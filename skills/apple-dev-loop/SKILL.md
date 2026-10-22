---
name: apple-dev-loop
description: The one guide to setting up, building, testing, launching, screenshotting and checking a DylKit app (Sconeos, Saga, Gattey Photos) on macOS or the iOS Simulator, without touching the installed release or stealing focus. Use for any local build, test run, visual check, or light/dark comparison.
---

# Apple dev loop

Every DylKit app builds the same way. READMEs and other skills link here instead of repeating it. Releasing, in CI and by hand on the Mac, is in `apple-release`.

## Shape

- SwiftPM only: the app is an executable target in the repo's `Package.swift`, and `DylApp.toml` holds the bundle, signing and release settings. There's no `.xcodeproj` or `.xcworkspace`, and `swiftpm_only` fails if one appears. Xcode is only the toolchain (`actool`, `simctl`, the SDKs); nobody opens a project in it.
- Asset catalogs, Core Data models and mapping models go in `[build] resources`, and the bundler compiles them into the main bundle with `actool`, `momc` and `mapc`. The app's target must `exclude:` them, or SwiftPM also copies them raw. Other SwiftPM resources ship as resource `.bundle`s, each with an `Info.plist`.
- The icon is a committed Icon Composer `.icon` in `[build] icon`, or `[build] icon-generator`, a script that writes one into `build/`.
- Info.plist keys DylKit doesn't derive go in `[bundle.info]` (macOS and iOS) or `[ios.info]` (iOS only). `[local-values]` fills Info.plist strings such as API credentials in every build, from the environment variable, then the gitignored xcconfig it names, then its `defaults`. CI has no xcconfig, so a release ships the defaults unless the workflow sets the variable.
- Swift 6 language mode, and state is `@Observable @MainActor` only, never `ObservableObject` (see `swiftui-viewmodels`).

## Setup

1. Select the Xcode 26.5 toolchain: `sudo xcode-select -s /Applications/Xcode_26.5.app/Contents/Developer`.
2. Run `mise install` in the repo. It installs the SwiftLint version pinned in `mise.toml` (and Node for the site). `./run dev checks` fails if SwiftLint is missing, doesn't run, or isn't the pinned version. It never skips SwiftLint.

## Commands

Run everything from the app repo through `./run dev …`, which builds `devkit` and finds `DylApp.toml`.

| Task | Command |
|---|---|
| Build `build/<App> Dev.app`, ad-hoc signed, with the commit count as its build number | `./run dev build` (or `./run dev build release`) |
| Rebuild and reopen behind the frontmost app | `./run dev relaunch` (add `--configuration release` for a Release build) |
| Screenshot the main window into `build/captures/` | `./run dev capture --appearance dark` |
| iOS Simulator, headless, with a screenshot | `./run dev ios --run --capture` (add `--simulator "<iPad name>"` for an iPad) |
| Unit tests | `swift test`. Test targets depend on `DylTestSupport` for ViewInspector and `AppDirectories.withTemporarySupportFolder`, so tests never read or write the real support folder |
| Lint tiers 1–3 | `./run dev checks` |
| What macOS CI runs: checks, build, then all tests | `./run dev verify` |
| Refresh `./run`, the PR check, the release workflow and the PR template after bumping DylKit | `./run dev sync` |
| Download site | `npm run dev` or `npm run build` in `server/` |

## Hard rules

- Only `build/` is ours. Never copy into, launch, kill or overwrite `/Applications/<App>.app` unless Dylan asks for a one-time install. `relaunch` only stops the process whose path is under `build/`.
- Dev builds are their own app: `<App> Dev`, bundle ID `<bundle-id>.dev`, URL schemes with a `-dev` suffix, and no Sparkle keys, so the updater stays off. `relaunch` and `capture` never share the installed app's preferences, Sparkle state, container, Keychain items or logs. Never launch anything that carries the release bundle ID, such as the staged release in `build/release/stage/`; compare it as below instead. An OAuth or URL callback reaches a dev build only if the provider also allows the `-dev` scheme. Otherwise call that flow unverified in dev.
- Launch with `open -g` only, capture with `screencapture -l <window>`, and run the simulator headless with `simctl`. Never use `osascript` (AppleScript `activate`, System Events keystrokes or menu clicks), `open` without `-g`, the app binary run directly, `open -a Simulator`, or a capture that raises a window. A screen you can't reach by a launch flag isn't verified on his Mac. Add an `--initial-view` for it or say it's unverified.
- devkit launches set `DYLKIT_BACKGROUND=1`. `LaunchOverrides.current.staysInBackground` reads it, and the app must never activate or raise a window under it. `DylUpdates` activates only in an installed release.
- Never change the system appearance. Pass `--appearance light|dark`: devkit applies it to that one process through AppKit's launch arguments, or to the simulator with `simctl ui`, so every window, sheet and menu follows it with no app code.
- Pick the starting screen with `--initial-view <name>` and the size with `--window-size 1280x800` instead of clicking through the UI. `AppWindow` applies the size by itself. The app maps the name to a screen with `LaunchOverrides.current.initialView.flatMap(Screen.init(rawValue:))`, where `Screen` is a `String` enum of the names it accepts. Apps never construct `LaunchOverrides`; devkit sets only `DYLKIT_*` variables.
- Captures wait for the screen to stop changing (spinners, fades, lazy loads) before saving, up to `--settle` seconds, 20 by default.
- Captures go to `build/captures/`. When sharing one, copy it to a new, uniquely versioned filename so image caches never show a stale render.

## Verify a release build without launching it

After `./run release bundle`, `sign` and `appcast`, run `./run release check --live`. It compares the staged app with the live release's signature, entitlements, Info.plist and feed. Expect only the version, build number and code hashes to differ. Never open either app to check.

## When a capture comes back wrong

- A blank or black PNG means Screen Recording isn't granted to the process running `devkit`. Say so instead of retrying.
- "No window" means the app hasn't shown its window within 15 seconds; check that it launched at all.
- "Still changing" means something animates forever, such as a looping spinner or a blinking caret. The capture is the last frame; look at it, and stop the animation under `--initial-view` if it hides what you're checking.
- The iOS build takes its bundle ID, plus `.dev`, and default simulator from the `[ios]` table of `DylApp.toml`.
