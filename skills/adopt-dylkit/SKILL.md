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
4. An app with installs: seed the store with the feed they read now, so Sparkle never sees an empty store. The seeded feed also tells `release-kit` that releases exist. An empty store reads as nothing shipped.
   1. Run `curl -fsSL <site>/appcast.xml -o appcast.xml`.
   2. On the store's page, open **Browser**, click **Upload**, and upload that file as `appcast.xml` at the store root.
   - Check: `curl -fsSL <assets>/appcast.xml` matches `curl -fsSL <site>/appcast.xml`.
5. Have Vercel install with the site's pinned pnpm.
   - An app whose site is new in the adoption PR has no site project yet. In the team, click **Add New…**, then **Project**, and import the app's repo. Set **Root Directory** to `server`, click **Deploy**, then add the `site-url` domain from `DylApp.toml`, such as `sudylko.gattey.com`, under **Settings**, **Domains**. The first deploy builds `main`, which has no site yet, and may fail; the adoption PR's preview is the one to check.
   1. Open the app's site project in Vercel, then **Settings**, then **Environment Variables**.
   2. Add `ENABLE_EXPERIMENTAL_COREPACK` with value `1` for every environment, as dylangattey.com's project has.
   3. Under **Settings**, **Build and Deployment**, leave **Install Command** on its default and set **Node.js Version** to 24.x, the version the site's `.node-version` pins.
   - Check: the next deploy's build log says `Detected ENABLE_EXPERIMENTAL_COREPACK=1 and "pnpm@…" in package.json` and `Done in … using pnpm v<the pinned version>`.

## A new app

1. Write `DylApp.toml`. `Sources/DylManifest/DylAppManifest.swift` in DylKit is the schema and `Tests/Fixtures/SampleApp/DylApp.toml` the smallest example.
2. Generate the Sparkle key pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` after the first `swift build`. Put the public key it prints in the file `[release] sparkle-public-key` names, run `generate_keys -x sparkle_ed.key`, and have Dylan paste that file's contents into the `SPARKLE_ED_PRIVATE_KEY_BASE64` secret. Delete the exported file.

## The adoption PR

1. Pin the release in `Package.swift`, `.package(url: "https://github.com/dgattey/dyl-kit", from: "<version>")`, then `swift package update dyl-kit`.
2. Copy `.github/workflows/dylkit.yml`, `.github/pull_request_template.md` and `.cursor/rules/changelog-release-notes.mdc` from DylKit's `Tests/Fixtures/SampleApp/` at that tag, and set `dylkit.yml`'s `@v<version>` to the pinned version. They're the app's from then on, and no DylKit bump rewrites them. Delete any release or PR-check workflow they replace. App-owned workflows such as `verify.yml` stay, running `swift run devkit verify`; SampleApp's `verify.yml` is one to copy if the app has none.
3. In `DylApp.toml`, under `[release]`, set `assets = "https://<store>.public.blob.vercel-storage.com"`.
4. Switch the site to `@dylkit/web`.
   1. Move `server/` to pnpm as in [0.5.x to 0.6.0](#05x-to-060), then depend on the `@dylkit/web` tarball for the DylKit version in `Package.resolved` and run `pnpm install` in `server/`. `dylkit_version` names the URL.
   2. Wrap `next.config.ts`'s config in `withDylKit` from `@dylkit/web/config`, and make `app/layout.tsx`, `app/page.tsx`, `app/releases/page.tsx`, `app/appcast.xml/route.ts`, `app/download/macos/route.ts` and the four icon routes the one-line re-exports in DylKit's README.
   - Delete the committed site icons (`app/icon.png`, `apple-icon.png`, `favicon.ico`, `public/app-icon.png`, `apple-icon.png`) and the icon-generator lines that write them. If the icon's light variant vanishes on a light tab, as Sconeos's does, set `favicon = "dark"` under `[site]`.
   3. In `server/vercel.json`, set `"ignoreCommand": "git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"`.
   - Check: `pnpm build` in `server/` succeeds.
5. An app with an `NSDockTilePlugIn`: keep its dynamic library product and set `[build] dock-tile-plugin` to that product and the plug-in's principal class. Delete the script steps that copied and signed the `.docktileplugin`, and the `NSDockTilePlugIn` key in the old `Info.plist`. The plug-in must find the app's preferences from its own bundle identifier, as DylKit's README says, so a dev build never reads the installed release's.
   - Check: `swift run devkit build`, then `codesign --verify --deep --strict "build/<App> Dev.app"` succeeds and `build/<App> Dev.app/Contents/PlugIns/` holds the plug-in.
6. Verify on the Mac: `swift run devkit checks` and `swift run release-kit check` report 0 errors, and `swift run devkit capture` shows the app.
7. Open the PR from the template with exactly one Release info box checked and plain-English `# Release notes`, as the rule file says. When it merges, the `dylkit` run tags `v<version>` and uploads to the store.
   - Check: `git ls-remote --tags origin v<version>` prints the tag, `curl -fsSL <assets>/release.json` shows that version, and `curl -fsSL <site>/appcast.xml` matches `curl -fsSL <assets>/appcast.xml`.
8. Backfill the releases from before DylKit into `history.json`: `swift run release-kit history --appcast <each older appcast.xml> --github <owner/name>` with `GITHUB_TOKEN` set, then `swift run release-kit history --publish` with `BLOB_READ_WRITE_TOKEN`.
   - Check: `<site>/releases` lists every version.

## Later upgrades

One PR moves the three pins to the same version, with their lockfiles:

1. `Package.swift`'s `from:`, then `swift package update dyl-kit` for `Package.resolved`.
2. The `@dylkit/web` tarball in `server/package.json`, then `pnpm install` in `server/` for `pnpm-lock.yaml`.
3. The `@v<version>` in `.github/workflows/dylkit.yml`.
   - Check: `swift run devkit checks` reports 0 errors; `dylkit_version` names any pin that differs from `Package.resolved`.

### 0.5.x to 0.6.0

0.6.0 moves sites from npm to pnpm, set up as dylangattey.com's is. `site_package_manager` in the checks fails a site without the pnpm pin or `pnpm-lock.yaml`, with `package-lock.json` or `yarn.lock`, or with npm's `overrides`, which pnpm ignores. Turborepo stays out: a site is one package with no task graph for it to cache.

A site still in an open PR, such as an adoption PR that adds `server/` to an app whose `main` has none, takes these steps on that PR's branch, not in a PR off `main`. That PR then pins 0.6.0, and its site never ships on npm.

1. Dylan: set the Vercel project's `ENABLE_EXPERIMENTAL_COREPACK=1`, as in Blob store and secrets step 5, which also creates the project for a site that has none yet. Without it Vercel picks a pnpm from the lockfile instead of the pin.
2. Move the three pins to 0.6.0 as above. Edit the tarball URL in `server/package.json` only; step 4's `pnpm install` writes the lockfile.
3. In `server/`, copy `packageManager`, the `preinstall` script and `pnpm-workspace.yaml` from DylKit's `Tests/Fixtures/SampleApp/server/` at `v0.6.0`, and its `.node-version`, which matches the Vercel project's Node 24. A `mise.toml` that pins `node` pins that same version.
4. Move any `"overrides"` in `server/package.json` to an `overrides:` map in `server/pnpm-workspace.yaml`, delete `server/package-lock.json` and any `server/.npmrc` that holds only npm settings, then run `pnpm install` in `server/`. When pnpm stops with `Ignored build scripts: <package>`, add `<package>: true` under `allowBuilds:` in `pnpm-workspace.yaml` (`sharp` below 0.34 has one) and run it again.
5. In each workflow that installs the site, replace `actions/setup-node`'s `cache: npm` step and `npm ci` with:

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

   Then `npm test`, `npm run <script>` and `npx <bin>` become `pnpm test`, `pnpm <script>` and `pnpm exec <bin>`, there and in scripts, docs, skills and rules.
6. Locally, `corepack enable pnpm` once, or any pnpm 10 or later, which switches to the pinned version itself.
   - Check: `swift run devkit checks` reports 0 errors, `pnpm install --frozen-lockfile`, `pnpm build` and the site's own test scripts pass in `server/`, and the PR's Vercel preview build log says it used the pinned pnpm.

### 0.3.x to 0.4.0

0.4.0 holds release notes to plain English. The PR check fails a PR whose `# Release notes` is missing or has file paths, code names, flags, CSS selectors, backticks or more than three bullets, and it re-runs whenever the PR body is edited. `release_notes` in the checks fails without the rule file or the template section. The download page no longer styles code in notes. Releases after 0.4.0 allow up to five bullets while still aiming for three; on those, copy the rule file and the template's `# Release notes` comment from SampleApp at the pinned version so agents see the new limit.

1. Pin `from: "0.4.0"` and run `swift package update dyl-kit`. In `server/package.json`, depend on `https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.4.0/dylkit-web-0.4.0.tgz` and run `npm install` in `server/`. Set `.github/workflows/dylkit.yml`'s `@v` to `v0.4.0`.
2. Copy `.cursor/rules/changelog-release-notes.mdc` from DylKit's `Tests/Fixtures/SampleApp/` at `v0.4.0`.
3. In `.github/pull_request_template.md`, put a `# Release notes` section above `# Release info` and keep it separate from `# What changed?`. SampleApp's template at `v0.4.0` has it, with the comment that goes under the heading.
   - Check: `swift run devkit checks` reports 0 errors, and `swift run release-kit notes --check --body-file <body.md>` passes on the upgrade PR's own body.

### 0.2.x to 0.3.2

0.3.0 drops `devkit sync` and `./run`: apps run `swift run devkit`, `swift run release-kit` and `swift run dyl-lint` directly, DylKit's PR check and release become one reusable workflow, and `@dylkit/web` reads `DylApp.toml` when Next builds instead of at request time, through `withDylKit`. `loadSite()` is gone.

1. Pin `from: "0.3.2"` and run `swift package update dyl-kit`. In `server/package.json`, depend on `https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.3.2/dylkit-web-0.3.2.tgz` and run `npm install` in `server/`.
2. Delete `.github/workflows/pr-check.yml` and `.github/workflows/release.yml`, and copy `.github/workflows/dylkit.yml` from DylKit's `Tests/Fixtures/SampleApp/` at `v0.3.2`, setting its `@v` to `v0.3.2`. It keeps their triggers and permissions, and `secrets: inherit` passes the app's `SPARKLE_ED_PRIVATE_KEY_BASE64` and `BLOB_READ_WRITE_TOKEN`. Add `BLOB_READ_WRITE_TOKEN` first if the repo lacks it, as in Blob store and secrets above.
3. Delete `./run`. Replace every `./run dev`, `./run release` and `./run lint` in workflows, scripts and docs with `swift run devkit`, `swift run release-kit` and `swift run dyl-lint`; a mode `./run` handed to `scripts/run` is now `scripts/run <mode>`. Delete the "Written by `devkit sync`" first line of `.github/pull_request_template.md`, which stays, owned by the app.
4. In `server/next.config.ts`, import `withDylKit` from `@dylkit/web/config` and export `withDylKit(nextConfig)`. Remove `transpilePackages`, which it adds, and any `outputFileTracingRoot` or `outputFileTracingIncludes`.
5. Replace `app/layout.tsx`, `app/page.tsx`, `app/appcast.xml/route.ts`, `app/download/macos/route.ts`, `app/icons/[name]/route.ts`, `app/icon.png/route.ts`, `app/apple-touch-icon.png/route.ts` and `app/favicon.ico/route.ts` with the one-line re-exports in DylKit's README.
6. In `server/vercel.json`, set `"ignoreCommand": "git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" && git diff --quiet \"$VERCEL_GIT_PREVIOUS_SHA\" HEAD -- . ../DylApp.toml"`. `site_deploy` rejects the 0.2.x `HEAD^` form.
   - Check: `swift run devkit checks` reports 0 errors, and `npm run build` in `server/` succeeds.

### 0.3.0 or 0.3.1 to 0.3.2

0.3.0's `ignoreCommand` exits 128 when Vercel's clone lacks the last deployed commit, as after a force-push or rebase, and Vercel fails the deploy. 0.3.2's checks that commit first and builds without it.

1. Move the three pins to 0.3.2 as above.
2. In `server/vercel.json`, replace the leading `[ -n \"$VERCEL_GIT_PREVIOUS_SHA\" ] &&` with `git rev-parse --quiet --verify \"$VERCEL_GIT_PREVIOUS_SHA^{commit}\" &&` and keep the paths. `site_deploy` names the whole command.
   - Check: `swift run devkit checks` reports 0 errors.
