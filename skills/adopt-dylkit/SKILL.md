---
name: adopt-dylkit
description: Adopt DylKit in an app, start to finish. Covers the Vercel Blob store and secrets, the four DylKit pins and the files copied once, DylApp.toml, the site's switch to `@dylkit/web`, the first release to Blob, and later upgrades.
---

# Adopt DylKit

Adoption is one PR. It moves the app onto DylKit and the site onto `@dylkit/web`, and its merge is the first release to Blob. An app with installs needs the store to hold its current feed before that PR merges.

## Blob store and secrets (the app's owner, once per app)

An agent can't create the store or set secrets. Hand the app's owner each step as written, then run its check.

One store per app: the newest `appcast.xml` and `release.json` sit at the store root, so two apps can't share one. The release workflow uploads to the store with its token. The site and Sparkle read the store's public URLs, which need no token.

1. Create the store.
   1. Open the Vercel team that holds the app's site project, and click the **Storage** tab.
   2. Click **Create Database**, pick **Blob**, and click **Continue**.
   3. Name it after the app, such as `<app>-releases`. Set access to **Public**. A private store's files can't be downloaded by Sparkle or the site.
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
4. An app with installs: seed the store with the feed they read now, so Sparkle never sees an empty store. The seeded feed also tells `release-kit` that releases exist. An empty store reads as nothing shipped.
   1. Run `curl -fsSL <site>/appcast.xml -o appcast.xml`.
   2. On the store's page, open **Browser**, click **Upload**, and upload that file as `appcast.xml` at the store root.
   - Check: `curl -fsSL <assets>/appcast.xml` matches `curl -fsSL <site>/appcast.xml`.
5. Have Vercel install with the site's pinned pnpm.
   - A site with no Vercel project yet, such as one the adoption PR adds, needs one first. In the team, click **Add New…**, then **Project**, and import the app's repo. Set **Root Directory** to `server`, click **Deploy**, then add the `site-url` domain from `DylApp.toml` under **Settings**, **Domains**. The first deploy builds `main`, which has no site yet, and may fail; the adoption PR's preview is the one to check.
   1. Open the app's site project in Vercel, then **Settings**, then **Environment Variables**.
   2. Add `ENABLE_EXPERIMENTAL_COREPACK` with value `1` for every environment.
   3. Under **Settings**, **Build and Deployment**, leave **Install Command** on its default and set **Node.js Version** to 24.x, the version the site's `.node-version` pins.
   - Check: the next deploy's build log says `Detected ENABLE_EXPERIMENTAL_COREPACK=1 and "pnpm@…" in package.json` and `Done in … using pnpm v<the pinned version>`.

## A new app

1. Write `DylApp.toml`. `Sources/DylManifest/DylAppManifest.swift` in DylKit is the schema and `Tests/Fixtures/SampleApp/DylApp.toml` the smallest example.
2. Generate the Sparkle key pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account <bundle-id>` after the first `swift build`, so it gets its own login Keychain account instead of Sparkle's `ed25519` one, which every app on the Mac shares. An app whose key is already in `ed25519` moves it: `generate_keys -x <file>`, then `generate_keys --account <bundle-id> -f <file>`. Write its public key to the file `[release] sparkle-public-key` names with `generate_keys --account <bundle-id> -p > <that file>`, run `generate_keys --account <bundle-id> -x sparkle_ed.key`, and have the app's owner paste that file's contents into the `SPARKLE_ED_PRIVATE_KEY_BASE64` secret. Delete the exported file.

## The adoption PR

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "<version>")`, then `swift package update dyl-kit`.
2. Copy `.github/workflows/dylkit.yml`, `.github/workflows/release-info.yml` and `.github/pull_request_template.md` from DylKit's `Tests/Fixtures/SampleApp/` at that tag, and set both workflows' `@v<version>` to the pinned version. They're the app's from then on, and no DylKit bump rewrites them. `dylkit.yml` runs `dylkit / verify` (`swift run devkit verify` on macOS) and the release, on `pull_request` types `opened`, `reopened`, `synchronize` and `closed`. Never add `edited`: GitHub grades the commit by its newest run, so an edit's run would replace verify's result, and `dylkit_version` fails it. `release-info.yml` runs `dylkit / release-info` on `opened`, `edited`, `reopened` and `synchronize`, so it checks the PR body on every edit. Delete any release, PR-check or verify workflow they replace. The rule for writing release notes comes with the DylKit plugin, so the app keeps no copy. `mise.toml` pins `swiftlint = "0.65.1"` under `[tools]`, like SampleApp's, and `.swiftlint.yml`, if the app has one, holds only its own `included` paths and rules with no `parent_config`.
3. In `DylApp.toml`, under `[release]`, set `assets = "https://<store>.public.blob.vercel-storage.com"`.
4. Install the site with pnpm. `site_package_manager` in the checks fails a site whose `server/package.json` or repo-root `package.json` doesn't hold DylKit's exact pnpm pin, and a site without `pnpm-lock.yaml`. The failure names the pin.
   1. In `server/`, copy `packageManager`, the `preinstall` script, `pnpm-workspace.yaml` and `.node-version` from DylKit's `Tests/Fixtures/SampleApp/server/` at that tag. `.node-version` matches the Vercel project's Node 24, and a `mise.toml` that pins `node` pins that same version.
   2. At the repo root, add a `package.json` holding only `"private": true` and the same `packageManager`, like SampleApp's. Vercel's CLI enables corepack from the clone root's `package.json`, not the Root Directory's, so without it Vercel installs with its own pnpm, which can't read the lockfile. Copy the pin rather than letting a tool write it: its hash is the npm registry's integrity for that pnpm, and corepack refuses any other. Add `/pnpm-lock.yaml` to `.gitignore`, as SampleApp's does, and delete any root `pnpm-lock.yaml`: pnpm writes one when it runs at the repo root, recording only its own version, which `server/pnpm-lock.yaml` already records. Anchor it with the leading `/` so `server/pnpm-lock.yaml` stays committed.
   3. Move any `"overrides"` in `server/package.json` to an `overrides:` map in `server/pnpm-workspace.yaml`. Delete `server/package-lock.json`, any `server/yarn.lock` and any `server/.npmrc` that holds only npm settings.
   4. Depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved`, then run `pnpm install` in `server/` and commit `pnpm-lock.yaml`. `dylkit_version` names the URL. When pnpm stops with `Ignored build scripts: <package>`, add `<package>: true` under `allowBuilds:` in `pnpm-workspace.yaml` for each dependency whose install script the site needs, and run it again.
   5. In each workflow that installs the site, set up pnpm and Node from the site's pins:

      ```yaml
      - uses: pnpm/action-setup@v6.1.0
        with:
          package_json_file: server/package.json
      - uses: actions/setup-node@v7.0.0
        with:
          node-version-file: server/.node-version
          cache: pnpm
          cache-dependency-path: server/pnpm-lock.yaml
      - run: pnpm install
        working-directory: server
      ```

      Scripts run as `pnpm test`, `pnpm <script>` and `pnpm exec <bin>` there and in scripts, docs, skills and rules, never `npm` or `npx`.
   6. Locally, run `corepack enable pnpm` once, or use any pnpm 10 or later, which switches to the pinned version itself.
   - Check: `pnpm install --frozen-lockfile` passes in `server/`.
5. Switch the site to `@dylkit/web`.
   1. Wrap `next.config.ts`'s config in `withDylKit` from `@dylkit/web/config`, and make `app/layout.tsx`, `app/page.tsx`, `app/releases/page.tsx`, `app/appcast.xml/route.ts`, `app/download/macos/route.ts` and the four icon routes the one-line re-exports in DylKit's README. SampleApp's `server/` holds each of them.
   - `server/tsconfig.json` sets `"moduleResolution": "bundler"`, as SampleApp's does; only that resolves `@dylkit/web`'s subpath exports. A site without one gets `node` from `next build`, which fails. `site_typescript` in the checks fails both.
   - Delete the committed site icons (`app/icon.png`, `apple-icon.png`, `favicon.ico`, `public/app-icon.png`, `apple-icon.png`) and the icon-generator lines that write them. If the icon's light variant vanishes on a light tab, set `favicon = "dark"` under `[site]`.
   2. In `server/vercel.json`, set `"ignoreCommand": "git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml ../package.json"`.
   - Check: in `server/`, `pnpm build` passes, which type-checks the site and is its only test unless it has a `test` script, in which case `pnpm test` passes too. The PR's Vercel preview build log says it used the pinned pnpm.
6. An app with an `NSDockTilePlugIn`: keep its dynamic library product and set `[build] dock-tile-plugin` to that product and the plug-in's principal class. Delete the script steps that copied and signed the `.docktileplugin`, and the `NSDockTilePlugIn` key in the old `Info.plist`. The plug-in must find the app's preferences from its own bundle identifier, as DylKit's README says, so a dev build never reads the installed release's.
   - Check: `swift run devkit build`, then `codesign --verify --deep --strict "build/<App> Dev.app"` succeeds and `build/<App> Dev.app/Contents/PlugIns/` holds the plug-in.
7. Verify on the Mac: `swift run devkit checks` and `swift run release-kit check` report 0 errors, and `swift run devkit capture` shows the app.
8. Point the default branch's ruleset at DylKit's checks, since a check the old workflows reported never arrives and blocks the PR. Its `required_status_checks` rule requires `dylkit / verify` and `dylkit / release-info`, each with `integration_id` 15368 (GitHub Actions), plus any other check a workflow the app keeps still reports, with `strict_required_status_checks_policy: false`.
   - Check: `required_checks` in `swift run devkit checks` warns about nothing.
9. Open the PR from the template with exactly one Release info box checked and plain-English `# Release notes`, as the plugin's release-notes rule says. When it merges, the `dylkit` run tags `v<version>` and uploads to the store.
   - Check: `git ls-remote --tags origin v<version>` prints the tag, `curl -fsSL <assets>/release.json` shows that version, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.
10. Backfill the releases from before DylKit into `history.json`: `swift run release-kit history --appcast <each older appcast.xml> --github <owner/name>` with `GITHUB_TOKEN` set, then `swift run release-kit history --publish` with `BLOB_READ_WRITE_TOKEN`.
   - Check: `<site>/releases` lists every version.

## Upgrading DylKit

One PR moves the four pins to the same version, with their lockfiles:

1. `Package.swift`'s `from:`, then `swift package update dyl-kit` for `Package.resolved`.
2. The `@dylkit/web` tarball in `server/package.json`, then `pnpm install` in `server/` for `pnpm-lock.yaml`.
3. The `@v<version>` in `.github/workflows/dylkit.yml` and `.github/workflows/release-info.yml`.
4. Whatever the checks then report, so the app matches this guide. The files copied once from SampleApp stay the app's; compare them with SampleApp's at the new tag.
   - Check: `swift run devkit checks` reports 0 errors; `dylkit_version` names any pin that differs from `Package.resolved`.
