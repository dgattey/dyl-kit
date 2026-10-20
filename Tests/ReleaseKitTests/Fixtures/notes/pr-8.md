Closes 

# Release notes

- **Readable in-app update notes:** Sparkle update dialogs now render concise, scannable HTML bullet points instead of raw PR markdown or blank descriptions.
- **Hourly background update checks:** Sconeos now checks for updates every hour in addition to checking immediately on launch.

# What changed?

- Added `scripts/format-release-notes.sh` (aligned with `dgattey/saga#41`) to extract `# Release notes` (falling back to `# Highlights`, `# What changed?`, `# Summary`, or `# Overview`), strip parenthetical file paths (`(Sources/...)`), and convert Markdown bullets, bold text, inline code, and links into styled HTML (`<ul><li style="margin-bottom: 6px; line-height: 1.45;">...</li></ul>`) for Sparkle's WebKit release-notes view.
- Updated `scripts/package-release.sh` to generate `Sconeos-${VERSION}.html` in the staging directory and invoke `generate_appcast --embed-release-notes --disable-signing-warning` so `<description><![CDATA[...]]></description>` is embedded directly in `server/public/appcast.xml`.
- Updated `.github/workflows/release-macos.yml` to extract both concise `sparkle_notes` (for `SCONEOS_RELEASE_NOTES`) and full `notes` (for the GitHub Release body), falling back to the merged PR title when a PR has no notes section.
- Added `# Release notes` to `.github/pull_request_template.md`.
- Updated `SUScheduledCheckInterval` in `scripts/build-macos.sh` from `86400` (24h) to `3600` (1h) to match Saga.

---

# Release info

Specify how to bump the version on merge (default: patch):
- [ ] Major (breaking / milestone release)
- [ ] Minor (new user-facing feature)
- [x] Patch (bug fix / polish / internal)
