# What changed?

- **Switch launch update check to `checkForUpdatesInBackground()` (`Sources/SconeosApp/AppUpdater.swift`)**:
  - Previously, `AppUpdaterModel.checkForUpdatesOnLaunch()` used `checkForUpdateInformation()` (a headless probe driver) paired with unstructured `Task { @MainActor in ... }` blocks in `SparkleUpdaterDelegate` that attempted to call `updater.checkForUpdates()` when an update was found. Because `didFindValidUpdate` and `didFinishUpdateCycleFor` run synchronously back-to-back on the main thread during probe abort, those two `Task`s could race or collide with `sessionInProgress`, and a successful probe required fetching `appcast.xml` twice.
  - Now calls `controller.updater.checkForUpdatesInBackground()` on every launch once the main window appears (skipping only if Sparkle's 24h scheduler already started a due check during `startingUpdater: true`), and implements `SPUStandardUserDriverDelegate`'s gentle scheduled update reminder hooks (`supportsGentleScheduledUpdateReminders = true`) so a found update is presented in immediate focus in a single pass while an up-to-date launch stays completely silent.
  - Replaces unstructured `Task { @MainActor in ... }` hops in `SparkleStandardUserDriverDelegate` and `SparkleUpdaterDelegate` with synchronous `MainActor.assumeIsolated` so `SparkleUpdateSession.shared` is updated before Sparkle closes its alert window.
- **Align local `scripts/build-macos.sh` version defaults with `appcast.xml`**:
  - Previously, running `./scripts/build-macos.sh` without env overrides stamped `CFBundleVersion` with `$(date +%s)` (e.g. `1776298800`), which is higher than the commit-count `<sparkle:version>` in `appcast.xml` (e.g. `14`) and caused Sparkle's `SUStandardVersionComparator` to treat any local build as newer than every published release.
  - Defaults `SCONEOS_APP_SHORT_VERSION` to `VERSION` and `SCONEOS_BUILD_NUMBER` to `git rev-list --count HEAD` when not explicitly overridden.

# Release info

- [ ] Major
- [ ] Minor
- [x] Patch
