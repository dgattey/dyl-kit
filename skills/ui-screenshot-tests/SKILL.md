---
name: ui-screenshot-tests
description: Verify UI changes with background screenshots of the real app in both appearances, and attach them to PRs. Use after any visual change and before saying a UI task is done.
---

# UI screenshot tests

1. Pick the screen and size through launch flags instead of clicking: `--initial-view <name>`, using a name the app defines (omit it for the home screen), and `--window-size 1280x800`.
2. Capture both appearances:

```bash
./run dev capture --appearance light
./run dev capture --appearance dark --no-build
./run dev ios --run --capture --appearance dark
```

3. Open each PNG and check it against the request: layout, truncation, highlight color, empty states, and both appearances. A capture you didn't look at isn't verification.
4. Copy the ones worth sharing to uniquely versioned filenames and put them in the PR description.

Captures launch `build/<App> Dev.app` in the background under its own `.dev` bundle ID, so they're safe on a Mac where the release is installed (see `apple-dev-loop`). A screen that needs a click, keystroke or menu to reach (Settings, a sheet) gets an `--initial-view` value instead.

Captures run against real data. If a screen needs data the machine doesn't have, say so instead of mocking it into the app.
