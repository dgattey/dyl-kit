---
name: apple-release
description: Cut, check or debug a Sparkle release of a DylKit macOS app — versioning from the PR checkbox, ad-hoc signing and the designated requirement, EdDSA, minimum OS, monotonic builds, MDM quarantine, and publishing the appcast. Use when a release fails, an update doesn't install, or release tooling changes.
---

# Apple release

The release is `release-kit`, run in steps by the shared `release` workflow (`./run dev sync` writes it) when a PR merges, or locally with `./run release <step>`:

1. `version --pr <n>` reads the merged PR's `# Release info` checkbox through the forge adapter (the merge commit message if that lookup fails), the tags and the published feeds, and writes `build/release/plan.json`. If HEAD already carries a release tag, it resumes that release, so rerunning a failed job finishes it.
2. `bundle` builds the release app into `build/release/stage` with bundle-relative rpaths only.
3. `sign` signs inside-out (frameworks, helpers, then the app), pins the designated requirement to the bundle ID, verifies, and zips.
4. `appcast` writes cumulative notes, the appcast with its enclosure on the forge, and `release.json`. It signs the enclosure with `SPARKLE_ED_PRIVATE_KEY_BASE64`, checks the signature against the key baked into the app, and runs the release checks against the staged feed.
5. `publish` tags `v<version>`, pushes the tag with plain git, and hands the zip, appcast and `release.json` to the forge adapter from `[release.forge]`. Nothing is committed.
6. CI's `live-site` job then waits on ubuntu until the site serves the new version's appcast and download page.

`./run release check` runs the same tier 3 checks on any branch, and `check --live` also compares the staged app with the live release (see `apple-dev-loop`). Its rule IDs explain themselves; read the finding instead of restating it here.

## By hand on the Mac

Use this when CI can't run, for example when Actions minutes run out. Run it on an up-to-date `main` with a clean tree, and never while the release workflow is running:

```sh
./run release version --type minor     # or --pr <n> to read the merged PR's checkbox
./run release bundle
./run release sign
./run release appcast                  # key: --ed-key-file, .cert/sparkle_ed.key, else the login Keychain
./run release check --live
./run release publish                  # needs GITHUB_TOKEN, or ORIGIN_TOKEN and BLOB_READ_WRITE_TOKEN
```

`./run release notes --body-file <pr-body.md>` previews the cumulative notes without releasing. Don't open the staged app to check it: it has the installed app's bundle ID. Run `./run release check --live` instead.

## Invariants

- The bump and notes come from the PR body, which needs exactly one checked box. No repo merge setting is involved. If neither the PR body nor the merge commit message checks exactly one box, `version` fails; rerun the workflow by hand with an explicit `release_type`.
- Only release-kit's forge adapters call a forge (`forge_neutral` enforces it), so any runner can drive the steps. The Origin adapter uploads to Vercel Blob because Origin has no release assets; it's untested.
- The published feeds are the site's feed and the forge's latest. Each is read strictly: only a 404 counts as no feed (a first release). An unreachable feed, any other error, or a feed that doesn't fully parse with an integer `sparkle:version` on every item fails the step.
- Build numbers only go up: the commit count, raised above every published `sparkle:version`. `publish` and `check --live` refuse a staged build older than either published feed, and the site refuses to serve a feed older than the one live when it was built.
- Each version in the cumulative notes is a `<section data-sparkle-version="BUILD">`. Sparkle 2.5+ marks the section matching the running `CFBundleVersion`, and the notes' `<style>` hides it and everything older. So notes must stay HTML, and stamps must be the exact `CFBundleVersion` string.
- The minimum OS in the appcast matches `[app] platforms` in `DylApp.toml`.
- Release files live on the forge, never in the repo. The site proxies the latest feed and redirects downloads to the latest zip.
- Releases queue one at a time and never cancel, so each plans from the tags the one before it pushed.

## Symptoms

- `-67050` or "the update is improperly signed": the new build's designated requirement doesn't match the installed one. `./run release check --live` reports it before release.
- The update alert hides behind other windows after a launch check: Sparkle doesn't activate the app for background checks. Use `DylUpdates`' `AppUpdater`, which brings found updates forward in focus, instead of an app-local Sparkle controller. It activates only an installed release: release-configured, in an Applications folder, and not launched with `DYLKIT_BACKGROUND`. Dev builds, tests and agent launches never take focus.
- Sparkle says "up to date" after a release: the build number didn't increase, or the CDN still serves the old appcast. Compare `<sparkle:version>` in `curl -fsSL <site>/appcast.xml` with the forge's latest `appcast.xml`.
- `/appcast.xml` or `/download/macos` answers 503: the forge's latest release is unreachable, or older than the feed the site replaced when it deployed. Publish a newer release. A redeploy can't fix it: its floor fetch gets the same 503 and fails the build.
- "Can't be opened" on first install: Gatekeeper quarantine on an ad-hoc build. System Settings → Privacy & Security → Open Anyway clears it once.
- Open Anyway fails with `-60005` on an MDM-managed Mac: the profile sets `DisableOverride = true`, which removes the override, and IT won't unset it. Run `xattr -cr /Applications/<App>.app` once. Sparkle's updates aren't quarantined, so it stays fixed. The download page's Gatekeeper section says this.
