# Overview

Sets up **`sconeos.gattey.com`** for macOS app downloads and Sparkle 2 auto-updates, matching the `photos.gattey.com` setup in `gattey-photos`, alongside the iOS top bar and Settings polish:

- **Next.js download site (`server/`)**:
  - Serves the Midnight Glass landing page at `/` with the live version/build read from `server/public/appcast.xml`, app preview screenshot, 5-crest waveform icon, and expandable macOS *Privacy & Security → Open Anyway* instructions.
  - Serves `/download/macos` (302 redirect to `/Sconeos-<version>.zip`) and `/appcast.xml` for Sparkle 2 updates.
  - Initial signed release `Sconeos-1.0.0.zip` (build `8`, EdDSA signed) committed in `server/public/`.
- **Automated release workflow (`.github/workflows/release-macos.yml` & `scripts/`)**:
  - Updated `package-release.sh`, `next-release-version.sh`, `fetch-live-macos-release.sh`, `macos-release-inputs-changed.sh`, and `export-ci-secrets.sh` so merged PRs to `main` build, sign, update `server/public/appcast.xml` + `server/public/Sconeos-<version>.zip`, and commit back to `main` to trigger Vercel Production deployment.
- **iOS top bar & Settings deduplication**:
  - Restores top-left Scone emblem and top-right speaker count badge in the iOS navigation bar without double borders, removes the duplicate speaker list in Settings, and shares `SpotifySidebarCard` across macOS and iOS.

# Release info
- [ ] Major (x.0.0)
- [ ] Minor (1.x.0)
- [x] Patch (1.0.x)
