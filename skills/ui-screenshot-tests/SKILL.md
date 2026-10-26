---
name: ui-screenshot-tests
description: Verify UI changes with background screenshots of the real app in both appearances, and attach them to PRs. Use after any visual change and before saying a UI task is done.
---

# UI screenshot tests

1. Capture the screen in light and dark with `apple-dev-loop`'s capture commands, picking it with `--initial-view <name>` and the size with `--window-size` instead of clicking. Capture the iOS Simulator too when the change reaches iOS.
2. Open each PNG and check it against the request: layout, truncation, highlight color, empty states, and both appearances. A capture you didn't look at isn't verification.
3. Copy the ones worth sharing to uniquely versioned filenames and put them in the PR description.

Captures launch `build/<App> Dev.app` in the background under its own `.dev` bundle ID, so they're safe on a Mac where the release is installed (see `apple-dev-loop`). A screen that needs a click, keystroke or menu to reach (Settings, a sheet) gets an `--initial-view` value instead. DylUI's `SettingsView` opens on one page for `settings/<page>`, the page's title lowercased with dashes for spaces, such as `settings/credits`.

Captures run against real data. If a screen needs data the machine doesn't have, say so instead of mocking it into the app.
