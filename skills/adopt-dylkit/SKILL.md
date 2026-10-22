---
name: adopt-dylkit
description: Adopt DylKit in an app, or upgrade one to DylKit 0.2, start to finish. Covers the Vercel Blob store and secrets, the SwiftPM pin, `./run dev sync`, DylApp.toml, the Swift API changes, the first release to Blob, and the follow-up PR that switches the site to `@dylkit/web`. Use for a fresh adoption, Sconeos's upgrade from 0.1, or finishing Saga's or Gattey Photos' adoption PR.
---

# Adopt DylKit

Adoption is two PRs. The first moves the app onto DylKit 0.2 and releases to Blob while the site keeps serving its committed feed. The second switches the site to `@dylkit/web` once the store has a release. Don't merge them in one PR: the site's new routes answer 503 until the store holds a release.

Work out the path first. It changes a few steps below.

- **Fresh.** No DylKit yet. Start with "Fresh only".
- **Upgrade from 0.1.** Sconeos: `main` pins DylKit 0.1 and commits its appcast to `server/public`.
- **Open adoption PR.** Saga and Gattey Photos: a branch that pins a DylKit branch or revision. Finish it as an upgrade, pinned to the release.

DylKit 0.2.0 must be released first. `git ls-remote --tags https://github.com/dgattey/dyl-kit v0.2.0` prints the tag, and the README's `@dylkit/web` line names its tarball URL.

## Blob store and secrets (Dylan, once per app)

An agent can't create the store or set secrets. Hand Dylan each step as written, then run its check.

One store per app: the newest `appcast.xml` and `release.json` sit at the store root, so two apps can't share one. The release workflow uploads to the store with its token. The site and Sparkle read the store's public URLs, which need no token.

1. Create the store.
   1. Open the Vercel team that holds the app's site project, and click the **Storage** tab.
   2. Click **Create Database**, pick **Blob**, and click **Continue**.
   3. Name it after the app, such as `saga-releases`. Set access to **Public**. A private store's files can't be downloaded by Sparkle or the site.
   4. Click **Create**. If Vercel offers to connect the store to a project, skip it.
   5. On the store's page, copy its public URL, `https://<store>.public.blob.vercel-storage.com`. PR 1 puts it in `DylApp.toml`.
   - Check: `curl -s -o /dev/null -w '%{http_code}' https://<store>.public.blob.vercel-storage.com/appcast.xml` prints `404` before the first release.
2. Copy the token.
   1. In the team's **Storage** tab, click the store.
   2. In its **Quickstart** section, open the **`.env.local`** tab and click **Show secret**.
   3. Copy the value of `BLOB_READ_WRITE_TOKEN`, without the quotes. It starts with `vercel_blob_rw_`.
3. Add it to GitHub.
   1. In the app's GitHub repo, open **Settings**, then **Secrets and variables**, then **Actions**.
   2. Under **Repository secrets**, click **New repository secret**.
   3. Set **Name** to `BLOB_READ_WRITE_TOKEN`, paste the token into **Secret**, and click **Add secret**.
   - Check: `gh secret list` shows `BLOB_READ_WRITE_TOKEN` and `SPARKLE_ED_PRIVATE_KEY_BASE64`.
4. Leave the Vercel project alone. Only the release workflow's Publish step reads the token, and the site's build and routes read public URLs. Connecting the store to the project is optional. It adds `BLOB_READ_WRITE_TOKEN` to the project's environment variables, which nothing reads.

## Fresh only

1. Write `DylApp.toml`. `Sources/DylManifest/DylAppManifest.swift` in DylKit is the schema and `Tests/Fixtures/SampleApp/DylApp.toml` the smallest example.
2. Generate the Sparkle key pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` after the first `swift build`. Put the public key it prints in the file `[release] sparkle-public-key` names, run `generate_keys -x sparkle_ed.key`, and have Dylan paste that file's contents into the `SPARKLE_ED_PRIVATE_KEY_BASE64` secret. Delete the exported file.
3. Run `swift run devkit sync` to write the first `./run`. Then follow PR 1 from step 2.

## PR 1: move to DylKit 0.2 and release to Blob

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "0.2.0")`, then `swift package update dyl-kit`.
   - Check: `Package.resolved` pins `dyl-kit` at `"version" : "0.2.0"`, not a branch or revision.
2. `./run dev sync`. It writes `./run`, `.github/workflows/pr-check.yml`, `.github/workflows/release.yml` and `.github/pull_request_template.md`, replacing an upgrade's 0.1 copies. App-owned workflows such as `verify.yml` stay.
   - Check: all four exist and `git diff` shows only DylKit's copies.
3. In `DylApp.toml`, under `[release]`, add `assets = "https://<store>.public.blob.vercel-storage.com"`. Delete `inputs` (DylKit rejects it) and any `[release.forge]` table (ignored; it only existed on pre-release branches).
4. Delete `ci/github/pr-body.sh`. Saga also deletes `verify-release.sh` (`./run release check --live` replaces it) and moves `format`, `ui` and `bootstrap` from its `./run` into an executable `scripts/run`, which `./run` hands every other mode.
5. In `.swiftlint.yml`, delete `parent_config`; devkit passes DylKit's config itself. `mise.toml` pins SwiftLint under `[tools]`.
6. Update the Swift code:
   - Launch overrides come only from `DYLKIT_*`. Sconeos replaces `LaunchOverrides(prefix:)` with `LaunchOverrides.current`, drops `launch:` from `AppWindow` and `AppUpdater.mainWindowDidAppear`, and renames its `SCONEOS_*` variables. Map `initialView` with `Screen.init(rawValue:)`.
   - `SettingsView(pages:)` and `SettingsWindow(palette:pages:)` take `sections:`; wrap pages in `SettingsSection(pages:)`. A `ThemePalette` type needs `init()`, and keeps `secondaryText`, `subtleFill` and `border` as its own properties if it uses them. Read the palette with `@Palette`, not `\.palette`. `StatusPill` and `SystemPalette` are gone.
   - Tests use `AppDirectories.withTemporarySupportFolder` instead of `setSupportFolderForTesting`.
   - Check: `swift build` succeeds.
7. Leave the site alone: its code, its `@dylkit/web` pin, and `server/public/appcast.xml` with the zips. `dylkit_web_version` skips while that appcast is committed.
8. List tags that never shipped. `version` plans from the highest tag, so one with no shipped zip skews it. Put the list in the PR for Dylan to confirm, and delete nothing yourself:

```sh
SITE=https://<app site>; REPO=dgattey/<app>
{
  curl -fsSL "$SITE/appcast.xml"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml"
  git log -p --format= -- server/public/appcast.xml
} | grep -o '<sparkle:shortVersionString>[^<]*' | sed 's/.*>/v/' > shipped.txt
gh api "repos/$REPO/releases" --paginate \
  -q '.[] | select(any(.assets[]; .name | endswith(".zip"))) | .tag_name' >> shipped.txt
git fetch --tags && git tag -l 'v*' | sort -u | comm -23 - <(sort -u shipped.txt)
```

9. Verify on the Mac: `./run dev checks` and `./run release check` report 0 errors, and `./run dev capture` shows the app in the macOS 26 design.
10. Open the PR from the synced template with exactly one Release info box checked. When it merges, the `release` run tags `v<version>` and uploads to the store. Its `live-site` job fails, as expected: the site still serves the committed feed.
    - Check: `git ls-remote --tags origin v<version>` prints the tag, and `curl -fsSL <assets>/release.json` shows that version.

## PR 2: switch the site to Blob

Start once PR 1's release is in the store.

1. In `server/package.json`, depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved`, `https://<DylKit's store>.public.blob.vercel-storage.com/releases/v0.2.0/dylkit-web-0.2.0.tgz`, and run `npm install`.
2. Wrap `next.config.ts` with `withDylKit`, add `app/appcast.xml/route.ts` and `app/download/macos/route.ts`, and render `DownloadPage` with `latestRelease`. DylKit's README has the code.
3. Delete `server/public/appcast.xml` and the committed zips; Next refuses a public file and a route at the same path. Saga also drops its `/appcast.xml` redirect.
4. Check: `npm run build` in `server/` succeeds (it reads the live site's feed for its floor), `./run dev checks` reports 0 errors now that `dylkit_web_version` compares the pins, and `npm run dev` serves `/appcast.xml` with PR 1's version.
5. Check one Release info box as the PR check requires. A PR that only touches `server/` doesn't release.
6. Once Vercel deploys it, re-run PR 1's failed `live-site` job (Actions → release → that run → Re-run failed jobs).
   - Check: the job passes, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.

## Later upgrades

Bump `from:` and run `swift package update dyl-kit`, then `./run dev sync`. Bump the `@dylkit/web` tarball to the same version in the same PR; `dylkit_web_version` names the URL when they differ. Then `./run dev checks`.
