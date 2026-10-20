# What changed?

- **Floating iOS Now Playing bar**: Redesigned `NowPlayingDock` on compact/iOS layouts into a floating Spotify-style mini-player pill (`spotifyFloatingPill`) detached from the bottom tab bar with rounded continuous corners, dark glass surface, volume popover, and live progress bar.
- **Fixed edge-to-edge sidebar & list items**: Replaced macOS sidebar `List` row insets with a clean `ScrollView` + `VStack` layout (14pt outer horizontal margins, 10pt inner row padding, and 18pt bottom padding on the Spotify footer card) and applied `.listStyle(.insetGrouped)` on iOS `Rooms` and `Settings` tabs.
- **Locked in 5-crest honey-butter glaze waveform icon**: Removed the experimental 3-variant icon switcher and standardized on the approved 5-crest waveform emblem across macOS and iOS.
- **Cleaned up Settings & headers**: Removed the duplicate speaker list from the iOS Settings tab and stripped all-caps section headers (`.textCase(nil)`).
- **Deduplicated `SconeUI`**: Consolidated speaker/group context menus into `SpeakerGroupContextMenu`, unified `SpotifyAccountView`, and shared `compactTabStack` across iOS tabs.
- **PR release-type checkbox & automated release workflow**: Added `.github/pull_request_template.md`, `scripts/next-release-version.sh`, `scripts/package-release.sh`, `scripts/ci-build-macos-release.sh`, `scripts/macos-release-inputs-changed.sh`, and `.github/workflows/release-macos.yml` to compute semantic version bumps (`Major` / `Minor` / `Patch`) from the merged PR's selected checkbox.

# Release info

- [ ] Major
- [x] Minor
- [ ] Patch
