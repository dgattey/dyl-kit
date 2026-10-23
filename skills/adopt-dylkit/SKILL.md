---
name: adopt-dylkit
description: Adopt DylKit in an app, start to finish. Covers the Vercel Blob store and secrets, the three DylKit pins and the files copied once, DylApp.toml, the site's switch to `@dylkit/web`, the first release to Blob, and later upgrades.
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

## The adoption PR

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "<version>")`, then `swift package update dyl-kit`.
2. Copy `.github/workflows/dylkit.yml`, `.github/pull_request_template.md` and `run` from DylKit's `Tests/Fixtures/SampleApp/` at that tag, and set `dylkit.yml`'s `@v<version>` to the pinned version. They're the app's from then on, and no DylKit bump rewrites them. Delete any release or PR-check workflow they replace; app-owned workflows such as `verify.yml` stay.
3. In `DylApp.toml`, under `[release]`, set `assets = "https://<store>.public.blob.vercel-storage.com"`.
4. Switch the site to `@dylkit/web`.
   1. In `server/package.json`, depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved` and run `npm install`. `dylkit_version` names the URL.
   2. Wrap `next.config.ts`'s config in `withDylKit` from `@dylkit/web/config`, and make `app/layout.tsx`, `app/page.tsx`, `app/appcast.xml/route.ts`, `app/download/macos/route.ts` and the four icon routes the one-line re-exports in DylKit's README.
   - Delete the committed site icons (`app/icon.png`, `apple-icon.png`, `favicon.ico`, `public/app-icon.png`, `apple-icon.png`) and the icon-generator lines that write them. If the icon's light variant vanishes on a light tab, as Sconeos's does, set `favicon = "dark"` under `[site]`.
   3. In `server/vercel.json`, set `"ignoreCommand": "[ -n \"$VERCEL_GIT_PREVIOUS_SHA\" ] && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"`.
   - Check: `npm run build` in `server/` succeeds.
5. An app with an `NSDockTilePlugIn`: keep its dynamic library product and set `[build] dock-tile-plugin` to that product and the plug-in's principal class. Delete the script steps that copied and signed the `.docktileplugin`, and the `NSDockTilePlugIn` key in the old `Info.plist`. The plug-in must find the app's preferences from its own bundle identifier, as DylKit's README says, so a dev build never reads the installed release's.
   - Check: `./run dev build`, then `codesign --verify --deep --strict "build/<App> Dev.app"` succeeds and `build/<App> Dev.app/Contents/PlugIns/` holds the plug-in.
6. Verify on the Mac: `./run dev checks` and `./run release check` report 0 errors, and `./run dev capture` shows the app.
7. Open the PR from the template with exactly one Release info box checked. When it merges, the `dylkit` run tags `v<version>` and uploads to the store.
   - Check: `git ls-remote --tags origin v<version>` prints the tag, `curl -fsSL <assets>/release.json` shows that version, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.

## Later upgrades

One PR moves the three pins to the same version, with their lockfiles:

1. `Package.swift`'s `from:`, then `swift package update dyl-kit` for `Package.resolved`.
2. The `@dylkit/web` tarball in `server/package.json`, then `npm install` in `server/` for `package-lock.json`.
3. The `@v<version>` in `.github/workflows/dylkit.yml`.
   - Check: `./run dev checks` reports 0 errors; `dylkit_version` names any pin that differs from `Package.resolved`.

### 0.2.x to 0.3.0

0.3.0 drops `devkit sync`: DylKit's PR check and release become one reusable workflow, and `@dylkit/web` reads `DylApp.toml` when Next builds instead of at request time, through `withDylKit`. `loadSite()` is gone.

1. Pin `from: "0.3.0"` and run `swift package update dyl-kit`. In `server/package.json`, depend on `https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.3.0/dylkit-web-0.3.0.tgz` and run `npm install` in `server/`.
2. Delete `.github/workflows/pr-check.yml` and `.github/workflows/release.yml`, and copy `.github/workflows/dylkit.yml` from DylKit's `Tests/Fixtures/SampleApp/` at `v0.3.0`. It keeps their triggers, permissions and secrets.
3. Delete the "Written by `devkit sync`" first line of `./run` and `.github/pull_request_template.md`. Both stay, owned by the app.
4. In `server/next.config.ts`, import `withDylKit` from `@dylkit/web/config` and export `withDylKit(nextConfig)`. Remove `transpilePackages`, which it adds, and any `outputFileTracingRoot` or `outputFileTracingIncludes`.
5. Replace `app/layout.tsx`, `app/page.tsx`, `app/appcast.xml/route.ts`, `app/download/macos/route.ts`, `app/icons/[name]/route.ts`, `app/icon.png/route.ts`, `app/apple-touch-icon.png/route.ts` and `app/favicon.ico/route.ts` with the one-line re-exports in DylKit's README.
6. In `server/vercel.json`, set `"ignoreCommand": "[ -n \"$VERCEL_GIT_PREVIOUS_SHA\" ] && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"`. `site_deploy` rejects the 0.2.x `HEAD^` form.
   - Check: `./run dev checks` reports 0 errors, and `npm run build` in `server/` succeeds.
