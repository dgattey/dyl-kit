---
name: apple-release
description: Cut, check or debug a Sparkle release of a DylKit macOS app — versioning from the PR checkbox, ad-hoc signing and the designated requirement, EdDSA, minimum OS, monotonic builds, MDM quarantine, and publishing the appcast. Use when a release fails, an update doesn't install, or release tooling changes.
---

# Apple release

The release is `release-kit`, run in steps by the CI wrapper or locally with `./run release <step>`:

1. `version` reads the merge commit's `# Release info` checkbox, the tags and the live appcast, and writes `build/release/plan.json`.
2. `bundle` builds the release app into `build/release/stage` with bundle-relative rpaths only.
3. `sign` signs inside-out (frameworks, helpers, then the app), pins the designated requirement to the bundle ID, verifies, and zips.
4. `appcast` writes cumulative notes and the appcast, signs the enclosure with `SPARKLE_ED_PRIVATE_KEY_BASE64`, and checks the signature against the key baked into the app.
5. `check` runs the release checks against the staged feed; `publish` commits `server/public/`, tags `v<version>` and pushes with plain git.
6. `check --live --wait 600` polls the deployed feed until it serves the new version with a valid signature.

`./run release check` runs the same tier 3 checks on any branch. Its rule IDs explain themselves; read the finding instead of restating it here.

## Invariants

- Version and notes come from git: the squash-merge message must carry the PR body (repo setting "Default to pull request title and description"). Without it the release falls back to a patch bump and warns.
- Build numbers only go up: the commit count, raised above every published `sparkle:version`.
- The minimum OS in the appcast matches `[app] platforms` in `DylApp.toml`.
- Nothing calls `gh`, `api.github.com` or GitHub Releases. Artifacts live in `server/public` and deploy with the site.

## Symptoms

- `-67050` or "the update is improperly signed": the new build's designated requirement doesn't match the installed one. Compare `codesign -d -r-` on both.
- Sparkle says "up to date" after a release: the build number didn't increase, or the CDN still serves the old appcast; run `check --live`.
- "Damaged and can't be opened" on first install: quarantine on an ad-hoc build. The download page's Gatekeeper note (`xattr -cr`) covers it; MDM-managed Macs need `DisableOverride` unset.
