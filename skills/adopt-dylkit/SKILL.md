---
name: adopt-dylkit
description: Adopt DylKit in an app, or upgrade one to DylKit 0.2, start to finish. Covers the Vercel Blob store and secrets, seeding the store with the current feed, the SwiftPM pin, `./run dev sync`, DylApp.toml, the Swift API changes, the site's switch to `@dylkit/web`, and the first release to Blob. Use for a fresh adoption, Sconeos's upgrade from 0.1, or finishing Saga's or Gattey Photos' adoption PR.
---

# Adopt DylKit

Adoption is one PR. It moves the app onto DylKit 0.2 and the site onto `@dylkit/web`, and its merge is the first release to Blob. Before it merges, the store must already hold the app's current feed and the repo must stop committing one. DylKit no longer reads a committed appcast, its git history or the 0.1 settings, so nothing flags a step skipped here.

Sconeos (`main`), Saga (PR #57) and Gattey Photos (PR #19) all pin DylKit 0.1.0 and its `@dylkit/web` 0.1.0 tarball, so each follows the adoption PR below. A new app starts with "Fresh only".

DylKit 0.2.0 must be released first. `git ls-remote --tags https://github.com/dgattey/dyl-kit v0.2.0` prints the tag, and the README's `@dylkit/web` line names its tarball URL.

## Blob store and secrets (Dylan, once per app)

An agent can't create the store or set secrets. Hand Dylan each step as written, then run its check.

One store per app: the newest `appcast.xml` and `release.json` sit at the store root, so two apps can't share one. The release workflow uploads to the store with its token. The site and Sparkle read the store's public URLs, which need no token.

1. Create the store.
   1. Open the Vercel team that holds the app's site project, and click the **Storage** tab.
   2. Click **Create Database**, pick **Blob**, and click **Continue**.
   3. Name it after the app, such as `saga-releases`. Set access to **Public**. A private store's files can't be downloaded by Sparkle or the site.
   4. Click **Create**. If Vercel offers to connect the store to a project, skip it.
   5. On the store's page, copy its public URL, `https://<store>.public.blob.vercel-storage.com`. The adoption PR puts it in `DylApp.toml`.
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
4. Seed the store with the feed installs read now, so Sparkle never sees an empty store. Skip this for a fresh app.
   1. Run `curl -fsSL <site>/appcast.xml -o appcast.xml`.
   2. On the store's page, open **Browser**, click **Upload**, and upload that file as `appcast.xml` at the store root.
   - Check: `curl -fsSL <assets>/appcast.xml` matches `curl -fsSL <site>/appcast.xml`.
5. Leave the Vercel project alone. Only the release workflow's Publish step reads the token, and the site's build and routes read public URLs. Connecting the store to the project is optional. It adds `BLOB_READ_WRITE_TOKEN` to the project's environment variables, which nothing reads.

## Fresh only

1. Write `DylApp.toml`. `Sources/DylManifest/DylAppManifest.swift` in DylKit is the schema and `Tests/Fixtures/SampleApp/DylApp.toml` the smallest example.
2. Generate the Sparkle key pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` after the first `swift build`. Put the public key it prints in the file `[release] sparkle-public-key` names, run `generate_keys -x sparkle_ed.key`, and have Dylan paste that file's contents into the `SPARKLE_ED_PRIVATE_KEY_BASE64` secret. Delete the exported file.
3. Run `swift run devkit sync` to write the first `./run`. Then follow the adoption PR from step 2.

## The adoption PR

Start once the store holds the seeded feed.

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "0.2.0")`, then `swift package update dyl-kit`.
   - Check: `Package.resolved` pins `dyl-kit` at `"version" : "0.2.0"`.
2. `./run dev sync`. It writes `./run`, `.github/workflows/pr-check.yml`, `.github/workflows/release.yml` and `.github/pull_request_template.md`, replacing an upgrade's 0.1 copies. App-owned workflows such as `verify.yml` stay.
   - Check: all four exist and `git diff` shows only DylKit's copies.
3. In `DylApp.toml`, under `[release]`, add `assets = "https://<store>.public.blob.vercel-storage.com"`. Delete `inputs`. DylKit ignores it now, so it would only mislead.
4. Delete `ci/github/pr-body.sh` (Sconeos and Gattey Photos). Saga moves `format`, `ui` and `bootstrap` from its `./run` into an executable `scripts/run`, which `./run` hands every other mode.
5. In `.swiftlint.yml`, delete `parent_config`. devkit passes DylKit's config itself and no longer flags a leftover one. `mise.toml` pins SwiftLint under `[tools]`.
6. Update the Swift code:
   - Launch overrides come only from `DYLKIT_*`. Replace `LaunchOverrides(prefix:)` with `LaunchOverrides.current`, drop `launch:` from `AppWindow` and `AppUpdater.mainWindowDidAppear`, and rename the app's own prefixed variables, such as Sconeos's `SCONEOS_*`. Map `initialView` with `Screen.init(rawValue:)`.
   - Saga's `SettingsView(pages:)` and `SettingsWindow(palette:pages:)` take `sections:`; wrap pages in `SettingsSection(pages:)`. Sconeos's `ThemePalette` type needs `init()`, and keeps `secondaryText`, `subtleFill` and `border` as its own properties. Read the palette with `@Palette`. `StatusPill` is gone.
   - Gattey Photos' tests use `AppDirectories.withTemporarySupportFolder` instead of its `AppConfig.setSupportFolderForTesting`.
   - Check: `swift build` succeeds.
7. Sconeos only: delete `server/public/appcast.xml`. 0.1's `release publish` committed it, and the synced release workflow doesn't. Keep its committed `server/public/Sconeos-*.zip` until the first 0.2 release ships: the seeded feed's enclosure still points at it.
8. Switch the site to Blob in the same PR.
   1. In `server/package.json`, depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved`, `https://<DylKit's store>.public.blob.vercel-storage.com/releases/v0.2.0/dylkit-web-0.2.0.tgz`, and run `npm install`. Every app pins 0.1.0 today, and `dylkit_web_version` fails until the versions match.
   2. Set `transpilePackages: ["@dylkit/web"]` in `next.config.ts`, add `app/appcast.xml/route.ts` and `app/download/macos/route.ts`, and render `DownloadPage` with `latestRelease`. DylKit's README has the code. Saga and Gattey Photos drop their `/appcast.xml` redirect to the latest GitHub release.
   - Check: `npm run build` in `server/` succeeds, and `npm run dev` serves `/appcast.xml` with the seeded feed. The download page and `/download/macos` stay unavailable until the first release writes `release.json`.
9. List tags that never shipped. `version` plans from the highest tag, so one with no shipped zip skews it. Put the list in the PR for Dylan to confirm, and delete nothing yourself:

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

10. Verify on the Mac: `./run dev checks` and `./run release check` report 0 errors, and `./run dev capture` shows the app in the macOS 26 design.
11. Open the PR from the synced template with exactly one Release info box checked. When it merges, the `release` run tags `v<version>` and uploads to the store.
    - Check: `git ls-remote --tags origin v<version>` prints the tag, `curl -fsSL <assets>/release.json` shows that version, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.
12. Sconeos only: in a follow-up PR, delete that zip. Check one Release info box as the PR check requires. A PR that only touches `server/` doesn't release.

## Later upgrades

Bump `from:` and run `swift package update dyl-kit`, then `./run dev sync`. Bump the `@dylkit/web` tarball to the same version in the same PR; `dylkit_web_version` names the URL when they differ. Then `./run dev checks`.
