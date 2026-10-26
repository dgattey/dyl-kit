# DylKit

A shared framework for Mac and iOS apps: the release pipeline, the dev loop, lint rules, runtime helpers, the download site, and the agent skills, in one copy every app depends on.

| Piece | What it is |
|---|---|
| `DylCore`, `DylUI`, `DylUpdates` | Runtime libraries: launch overrides, networking helpers, the palette shape each app fills in, the main window and the Settings window, and Sparkle updates (inert on iOS and in dev builds). |
| `devkit` | Build, relaunch and screenshot the app in the background, the iOS Simulator loop, and every check a PR needs. |
| `release-kit` | Version, bundle, sign, appcast and publish a Sparkle release to the app's Vercel Blob store, plus the release invariant checks. |
| `dyl-lint` | SwiftSyntax rules for concurrency and state bugs that shipped in these apps. `lint/swiftlint.yml` holds the regex tier. |
| `DylManifest` | Reads each app's `DylApp.toml`. |
| `web/` (`@dylkit/web`) | Each app's download site, built from its `DylApp.toml` and serving the latest release from Blob. |
| `skills/`, `rules/` | The DylKit Cursor plugin. |

## Using it in an app

The skills hold the how-to: `adopt-dylkit` covers adoption and upgrades (the Blob store and secrets, `DylApp.toml`, the files copied once from `Tests/Fixtures/SampleApp/`, the site's pnpm setup), `apple-dev-loop` covers building, testing, screenshots and the checks, and `apple-release` covers releasing, in CI and by hand. The plugin's `changelog-release-notes` rule says how to write each PR's `# Release notes`, which the PR check enforces.

An app depends on DylKit twice, and pins it in four places to the same version:

```swift
// Package.swift
.package(url: "https://github.com/dgattey/dyl-kit", from: "<version>"),
```

```json
// server/package.json, the tarball DylKit's release uploads
"@dylkit/web": "https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v<version>/dylkit-web-<version>.tgz"
```

```yaml
# .github/workflows/dylkit.yml
uses: dgattey/dyl-kit/.github/workflows/app.yml@v<version>
# .github/workflows/release-info.yml
uses: dgattey/dyl-kit/.github/workflows/release-info.yml@v<version>
```

`dylkit_version` fails when the tarball or a workflow ref isn't the DylKit version in `Package.resolved`. A bump changes those four lines and the lockfiles; nothing is generated or synced.

## Download site

`@dylkit/web` is each app's download site. `withDylKit` reads `DylApp.toml` and the screenshots' sizes when Next loads its config, so nothing reads them at request time. Its pages and routes are one-line re-exports, which `server/tsconfig.json`'s `"moduleResolution": "bundler"` resolves, and it serves the latest release from the app's Blob store:

```ts
// next.config.ts
import { withDylKit } from "@dylkit/web/config";
export default withDylKit({});

// app/layout.tsx
export { Layout as default, metadata } from "@dylkit/web/app";

// app/page.tsx
export { Page as default } from "@dylkit/web/app";

// app/releases/page.tsx, every version's notes, where the update dialog links
export { Releases as default, releasesMetadata as metadata } from "@dylkit/web/app";

// app/appcast.xml/route.ts
export { appcast as GET } from "@dylkit/web/routes";

// app/download/macos/route.ts
export { download as GET } from "@dylkit/web/routes";

// app/icons/[name]/route.ts, and the same in app/icon.png/, app/apple-touch-icon.png/ and app/favicon.ico/
export { icon as GET } from "@dylkit/web/routes";
```

The default page is a hero with the first screenshot, the rest as a gallery, the features and the release notes, all from `[site]`:

```toml
[site]
tagline = "One line under the app's name."
accent = { light = "#467e61", dark = "#6fae8c" }
heading-font = "serif"                  # or "sans", the default
screenshots = [                         # under release.artifacts-dir; PNG or WebP
    { src = "mac.png", dark-src = "mac-dark.png", alt = "…" },
    { src = "phone.webp", alt = "…", frame = "iphone" },
]
features = [{ title = "…", body = "…" }]
```

An app that wants its own layout writes `app/page.tsx` from the pieces `@dylkit/web` exports: `SitePage`, `Hero` (with its own `visual`, `title` or `lead`), `Section`, `Showcase`, `Features` and `Feature` (with any `glyph`), `ReleaseNotes`, `latestRelease` and `site`. The kit's CSS is in `@layer dylkit`, so the app's own CSS and CSS Modules override it without fighting specificity, and an app restyles the whole page by setting the theme tokens (`--canvas`, `--paper`, `--ink`, `--ink-muted`, `--line`, `--shadow`) on `:root`.

`server/vercel.json`'s `ignoreCommand` must watch `../DylApp.toml`, which the build reads, and `../package.json`, whose pnpm pin Vercel installs with: `git rev-parse --quiet --verify "$VERCEL_GIT_PREVIOUS_SHA^{commit}" && git diff --quiet "$VERCEL_GIT_PREVIOUS_SHA" HEAD -- . ../DylApp.toml ../package.json`.

Sites commit no icons. Each release renders them from the app's `.icon` and uploads them to the store's `icons/`, and the icon routes serve them. Other sites can embed `/icon.png` (1024 px) and `/apple-touch-icon.png` (180 px, opaque), so keep those paths and sizes. `[site] favicon = "dark"` puts the dark favicon in the tab.

## Dock tile plug-in

An `NSDockTilePlugIn` draws the app's Dock icon while the app is quit. Put its principal class in a target of its own, give the class an Objective-C name with `@objc(SampleDockTilePlugIn)`, and ship the target as a dynamic library product:

```swift
.library(name: "SampleDockTile", type: .dynamic, targets: ["SampleDockTile"]),
```

```toml
[build]
dock-tile-plugin = { product = "SampleDockTile", principal-class = "SampleDockTilePlugIn" }
```

Release and dev builds both build the library and wrap it as `Contents/PlugIns/SampleDockTile.docktileplugin`. They sign it before the app and set the app's `NSDockTilePlugIn`. `Tests/Fixtures/SampleApp/Sources/SampleDockTile` is a working example.

The Dock loads the plug-in into its own process, so `UserDefaults.standard` there is the Dock's. The plug-in's bundle identifier is the app's plus `.docktile`. Read the app's preferences from that identifier minus `.docktile`, for example with `CFPreferencesCopyAppValue`. Never hardcode the app's bundle ID or a suite name. A dev build is `<bundle-id>.dev`, and a hardcoded domain would draw the installed release's settings on the dev build's icon.

## Cursor plugin

This repo is a Cursor plugin (`.cursor-plugin/plugin.json`). It ships the skills and the always-applied `dylkit` and `changelog-release-notes` rules, so every app gets one canonical copy without copying them. To use it locally, link the checkout into Cursor's local plugins:

```sh
ln -s ~/repos/dyl-kit ~/.cursor/plugins/local/dylkit
```

For cloud agents and teammates, add `dgattey/dyl-kit` to the team's plugin marketplace.

## Developing

```sh
swift build && swift test         # Tests/Fixtures/SampleApp stands in for an app
swift run dyl-lint Sources
cd web && pnpm install && pnpm test
scripts/release-e2e.sh            # version, bundle, sign, appcast and publish --dry-run SampleApp with a generated Ed key
```

CI runs the same on every PR. Docs-only changes skip CI.

SampleApp depends on DylKit with `.package(path: "../../..")`, and SwiftPM names a path dependency after its folder, so the checkout or worktree folder must be named `dyl-kit`. Anything else fails with `unknown package 'dyl-kit'`; use a worktree path such as `/tmp/dk-<sha>/dyl-kit`.

## Releasing DylKit

Merging a PR to `main` releases DylKit like an app, minus the app. The PR's `# Release info` box picks the bump, and the `release` workflow tags the merge commit and uploads the `@dylkit/web` tarball to `releases/v<version>/` in DylKit's Blob store. When PRs merge while a release runs, GitHub cancels all but the newest one's run, so a release also ships any earlier merges without a tag, with the largest of their bumps and all of their notes; apps release the same way. The tag is the only version: `web/package.json` stays at `0.0.0`, and the plugin manifest has none, because Cursor updates plugins from the branch's commits. Apps bump the package dependency, the tarball URL and the workflow ref together. DylKit's own PRs run the same `app.yml` Release info and Release notes checks apps call, and follow the same `rules/changelog-release-notes.mdc`, which `.cursor/rules/` links to.

### Running a PR in an app before it releases

CI's `prerelease` job packs each commit of a DylKit PR as `@dylkit/web` `<last tag>-pr.<number>.<short sha>`, uploads it to `releases/pr-<number>/` in the same store without tagging anything, and fails unless the URL then serves it. It runs after the `swift` and `web` jobs, a few minutes after the push, and a newer push cancels the older commit's run, so only commits CI finished get a tarball. Its run summary names the three pins that select that commit:

```swift
.package(
    url: "https://github.com/dgattey/dyl-kit",
    revision: "<sha>"
)
```

plus `@<sha>` on both workflows' `uses:` and the tarball URL in `server/package.json`. With a revision pin in `Package.resolved`, `dylkit_version` fails a workflow ref other than that full SHA and a tarball without its `.<short sha>` suffix. Move all four to the release once it ships.
