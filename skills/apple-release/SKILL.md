---
name: apple-release
description: Cut, check or debug a Sparkle release of a DylKit macOS app — versioning from the PR checkbox, ad-hoc signing and the designated requirement, EdDSA, minimum OS, monotonic builds, MDM quarantine, and publishing the appcast. Use when a release fails, an update doesn't install, or release tooling changes.
---

# Apple release

The release is `release-kit`, run in steps by the CI wrapper or locally with `./run release <step>`:

1. `version` reads the merged PR's `# Release info` checkbox (from `--pr-body-file`, which `ci/github/pr-body.sh` fetches; the merge commit message if that lookup fails), the tags and the live appcast, and writes `build/release/plan.json`.
2. `bundle` builds the release app into `build/release/stage` with bundle-relative rpaths only.
3. `sign` signs inside-out (frameworks, helpers, then the app), pins the designated requirement to the bundle ID, verifies, and zips.
4. `appcast` writes cumulative notes and the appcast, signs the enclosure with `SPARKLE_ED_PRIVATE_KEY_BASE64`, and checks the signature against the key baked into the app.
5. `check` runs the release checks against the staged feed; `publish` commits `server/public/`, tags `v<version>` and pushes with plain git.
6. CI's `live-site` job then waits on ubuntu until the site serves the new version's appcast and download page.

`./run release check` runs the same tier 3 checks on any branch. Its rule IDs explain themselves; read the finding instead of restating it here.

## By hand on the Mac

Use this when CI can't run, for example when Actions minutes run out. Run it on an up-to-date `main` with a clean tree, and never while the release workflow is running:

```sh
./run release version --type minor     # or --pr-body-file <merged-pr-body.md> to read its checkbox
./run release bundle
./run release sign
./run release appcast                  # key: --ed-key-file, .cert/sparkle_ed.key, else the login Keychain
./run release check
./run release publish                  # --no-push commits and tags without pushing
```

`./run release notes --body-file <pr-body.md>` previews the cumulative notes without releasing. Don't open the staged app to check it: it has the installed app's bundle ID. Compare Info.plist, signatures and entitlements as in `apple-dev-loop` instead.

## Invariants

- The bump and notes come from the PR body, which needs exactly one checked box. No repo merge setting is involved. If neither the PR body nor the merge commit message checks exactly one box, `version` fails; rerun the workflow by hand with an explicit `release_type`.
- Only `ci/github/` may call a forge API (`forge_neutral` enforces it). An Origin wrapper would sit next to it and hand release-kit the same file.
- Build numbers only go up: the commit count, raised above every published `sparkle:version`.
- Each version in the cumulative notes is a `<section data-sparkle-version="BUILD">`. Sparkle 2.5+ marks the section matching the running `CFBundleVersion`, and the notes' `<style>` hides it and everything older. So notes must stay HTML, and stamps must be the exact `CFBundleVersion` string.
- The minimum OS in the appcast matches `[app] platforms` in `DylApp.toml`.
- Nothing calls `gh`, `api.github.com` or GitHub Releases. Artifacts live in `server/public` and deploy with the site; the site's Vercel `ignoreCommand` must never skip them (`site_deploy`).
- `version` fast-forwards to `origin/<branch>` before planning, so a release queued behind another plans from, and pushes onto, the newer commit.

## Symptoms

- `-67050` or "the update is improperly signed": the new build's designated requirement doesn't match the installed one. Compare `codesign -d -r-` on both.
- The update alert hides behind other windows after a launch check: Sparkle doesn't activate the app for background checks. Use `DylUpdates`' `AppUpdater`, which brings found updates forward in focus, instead of an app-local Sparkle controller. It activates only an installed release: release-configured, in an Applications folder, and not launched with `DYLKIT_BACKGROUND`. Dev builds, tests and agent launches never take focus.
- Sparkle says "up to date" after a release: the build number didn't increase, or the CDN still serves the old appcast. Compare `<sparkle:version>` in `curl -fsSL <site>/appcast.xml` with the committed one.
- "Can't be opened" on first install: Gatekeeper quarantine on an ad-hoc build. System Settings → Privacy & Security → Open Anyway clears it once.
- Open Anyway fails with `-60005` on an MDM-managed Mac: the profile sets `DisableOverride = true`, which removes the override, and IT won't unset it. Run `xattr -cr /Applications/<App>.app` once. Sparkle's updates aren't quarantined, so it stays fixed. The download page's Gatekeeper section says this.
