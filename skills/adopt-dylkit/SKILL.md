---
name: adopt-dylkit
description: Adopt DylKit in an app, start to finish. Covers the Vercel Blob store and secrets, the SwiftPM pin, `./run dev sync`, DylApp.toml, the site's switch to `@dylkit/web`, the first release to Blob, and later upgrades.
---

# Adopt DylKit

Adoption is one PR. It moves the app onto DylKit and the site onto `@dylkit/web`, and its merge is the first release to Blob. An app with installs needs the store to hold its current feed before that PR merges.

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
4. An app with installs: seed the store with the feed they read now, so Sparkle never sees an empty store.
   1. Run `curl -fsSL <site>/appcast.xml -o appcast.xml`.
   2. On the store's page, open **Browser**, click **Upload**, and upload that file as `appcast.xml` at the store root.
   - Check: `curl -fsSL <assets>/appcast.xml` matches `curl -fsSL <site>/appcast.xml`.

## A new app

1. Write `DylApp.toml`. `Sources/DylManifest/DylAppManifest.swift` in DylKit is the schema and `Tests/Fixtures/SampleApp/DylApp.toml` the smallest example.
2. Generate the Sparkle key pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` after the first `swift build`. Put the public key it prints in the file `[release] sparkle-public-key` names, run `generate_keys -x sparkle_ed.key`, and have Dylan paste that file's contents into the `SPARKLE_ED_PRIVATE_KEY_BASE64` secret. Delete the exported file.
3. Run `swift run devkit sync` to write the first `./run`.

## The adoption PR

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "<version>")`, then `swift package update dyl-kit`.
2. `./run dev sync`. It writes `./run`, `.github/workflows/pr-check.yml`, `.github/workflows/release.yml` and `.github/pull_request_template.md`. App-owned workflows such as `verify.yml` stay.
3. In `DylApp.toml`, under `[release]`, set `assets = "https://<store>.public.blob.vercel-storage.com"`.
4. Switch the site to `@dylkit/web`.
   1. In `server/package.json`, depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved` and run `npm install`. `dylkit_web_version` names the URL.
   2. Set `transpilePackages: ["@dylkit/web"]` in `next.config.ts`, add `app/appcast.xml/route.ts` and `app/download/macos/route.ts`, and render `DownloadPage` with `latestRelease`. DylKit's README has the code.
   3. In `server/vercel.json`, set `"ignoreCommand": "git diff --quiet \"${VERCEL_GIT_PREVIOUS_SHA:-HEAD^}\" HEAD -- . ../DylApp.toml"`.
   - Check: `npm run build` in `server/` succeeds.
5. Verify on the Mac: `./run dev checks` and `./run release check` report 0 errors, and `./run dev capture` shows the app.
6. Open the PR from the synced template with exactly one Release info box checked. When it merges, the `release` run tags `v<version>` and uploads to the store.
   - Check: `git ls-remote --tags origin v<version>` prints the tag, `curl -fsSL <assets>/release.json` shows that version, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.

## Later upgrades

Bump `from:` and run `swift package update dyl-kit`, then `./run dev sync`. Bump the `@dylkit/web` tarball to the same version in the same PR; `dylkit_web_version` names the URL when they differ. Then `./run dev checks`.
