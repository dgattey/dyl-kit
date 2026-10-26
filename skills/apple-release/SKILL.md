---
name: apple-release
description: Cut, check or debug a Sparkle release of a DylKit macOS app — versioning from the PR checkbox, ad-hoc signing and the designated requirement, EdDSA, minimum OS, monotonic builds, MDM quarantine, and publishing the appcast. Use when a release fails, an update doesn't install, or release tooling changes.
---

# Apple release

The release is `release-kit`, run in steps by DylKit's reusable `app` workflow, which the app's `.github/workflows/dylkit.yml` calls, when a PR merges, or locally with `swift run release-kit <step>`:

1. `version --pr <n>` reads the merged PR's `# Release info` checkbox from GitHub (the merge commit message if that lookup fails), the tags and the published feeds, and writes `build/release/plan.json`. If HEAD already carries a release tag, it resumes that release, so rerunning a failed job finishes it.
2. `bundle` builds the release app into `build/release/stage` with bundle-relative rpaths only.
3. `sign` signs inside-out (frameworks, helpers, then the app), pins the designated requirement to the bundle ID, verifies, and zips.
4. `appcast` writes cumulative notes, the appcast with its enclosure on the app's Blob store, `release.json`, and `history.json` (the published history plus this release; a rerun replaces its own entry). It signs the enclosure with `SPARKLE_ED_PRIVATE_KEY_BASE64`, checks the signature against the key baked into the app, and runs the release checks against the staged feed.
5. `publish` tags `v<version>`, pushes the tag with plain git, and uploads the zip to `releases/v<version>/` in the Blob store at `[release] assets`, then `history.json`, the appcast and `release.json` to its root. Nothing is committed, and there's no GitHub release.
6. CI's `live-site` job then waits on ubuntu until the site serves the new version's appcast and download page.

`swift run release-kit check` runs the same tier 3 checks on any branch, and `check --live` also compares the staged app with the live release (see `apple-dev-loop`). Its rule IDs explain themselves; read the finding instead of restating it here.

## By hand on the Mac

Use this when CI can't run, for example when Actions minutes run out. Run it on an up-to-date `main` with a clean tree, and never while the release workflow is running:

```sh
swift run release-kit version --type minor     # or --pr <n> to read the merged PR's checkbox
swift run release-kit bundle
swift run release-kit sign
swift run release-kit appcast                  # signs with the first key that matches SUPublicEDKey, see below
swift run release-kit check --live
swift run release-kit publish                  # needs BLOB_READ_WRITE_TOKEN; --dry-run uploads nothing
```

`appcast` tries `--ed-key-file`, else `SPARKLE_ED_PRIVATE_KEY_BASE64`, else `.cert/sparkle_ed.key`, `sparkle_private.key`, `~/.config/<slug>/sparkle_ed.key` (the slug is the app name, lowercase and hyphenated), the login Keychain account named after the bundle ID, and Sparkle's shared `ed25519` account. It signs the archive with each and uses the first whose signature `SUPublicEDKey` verifies, before `generate_appcast` runs; when none does, it lists what each location held. Sparkle's shared account holds whichever app's key was generated last on that Mac, so store each app's key in its own account: `generate_keys --account <bundle-id> -f <exported key>`. To rehearse without the app's key, run `appcast --throwaway-key`, then `publish --dry-run`. A real `publish` re-verifies the appcast against `SUPublicEDKey` and refuses it.

`swift run release-kit notes --body-file <pr-body.md>` previews the cumulative notes without releasing, and `--check` runs the PR check's Release notes rules on that body instead. Don't open the staged app to check it: it has the installed app's bundle ID. Run `swift run release-kit check --live` instead.

## Invariants

- The bump and notes come from the PR body, which needs exactly one checked box. No repo merge setting is involved. If neither the PR body nor the merge commit message checks exactly one box, `version` fails; rerun the workflow by hand with an explicit `release_type`.
- Only release-kit calls a forge (`forge_neutral` enforces it), and only to read the PR body.
- The published feeds are the site's feed and the Blob store's latest. The store decides whether anything has shipped, since `publish` uploads its feed last and the site only proxies it. Only the store's 404 means nothing has shipped. Then the tags plan the release, and a site that can't serve a feed is skipped: a host that doesn't resolve before the first deploy, or the route's 503. Once the store has a feed, any other error from either feed fails the step, as does a feed without an integer `sparkle:version` on every item.
- Build numbers only go up: the commit count, raised above every published `sparkle:version`. `publish` and `check --live` refuse a staged build older than either published feed.
- Each version in the cumulative notes is a `<section data-sparkle-version="BUILD">`. Sparkle 2.5+ marks the section matching the running `CFBundleVersion`, and the notes' `<style>` hides it and everything older. So notes must stay HTML, and stamps must be the exact `CFBundleVersion` string.
- The minimum OS in the appcast matches `[app] platforms` in `DylApp.toml`.
- Release files live on Blob, never in the repo or on the forge. The site proxies the latest feed and redirects downloads to the latest zip.
- Releases queue one at a time and never cancel, so each plans from the tags the one before it pushed.

## Symptoms

- `-67050` or "the update is improperly signed": the new build's designated requirement doesn't match the installed one. `swift run release-kit check --live` reports it before release.
- The update alert hides behind other windows after a launch check: Sparkle doesn't activate the app for background checks. Use `DylUpdates`' `AppUpdater`, which brings found updates forward in focus, instead of an app-local Sparkle controller. It activates only an installed release: release-configured, in an Applications folder, and not launched with `DYLKIT_BACKGROUND`. Dev builds, tests and agent launches never take focus.
- Sparkle says "up to date" after a release: the build number didn't increase, or the CDN still serves the old appcast. Compare `<sparkle:version>` in `curl -fsSL <site>/appcast.xml` with `<assets>/appcast.xml`.
- `/appcast.xml` or `/download/macos` answers 503: the Blob store's latest `appcast.xml` or `release.json` is unreachable or incomplete. Compare it with `curl -fsSL <assets>/appcast.xml`, and publish again if it's broken.
- "Can't be opened" on first install: Gatekeeper quarantine on an ad-hoc build. System Settings → Privacy & Security → Open Anyway clears it once.
- Open Anyway fails with `-60005` on an MDM-managed Mac: the profile sets `DisableOverride = true`, which removes the override, and IT won't unset it. Run `xattr -cr /Applications/<App>.app` once. Sparkle's updates aren't quarantined, so it stays fixed. The download page's Gatekeeper section says this.
