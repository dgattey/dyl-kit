# DylKit

The shared framework for Dylan's Mac and iOS apps (Sconeos, Saga, Gattey Photos). One copy of what each app used to copy from the others: the release pipeline, the dev loop, lint rules, runtime helpers, the download site, and the agent skills.

| Piece | What it is |
|---|---|
| `DylCore`, `DylUI`, `DylUpdates` | Runtime libraries: launch overrides, networking helpers, the palette shape each app fills in, the main window and the Settings window, and Sparkle updates (inert on iOS and in dev builds). |
| `DylTestSupport` | For apps' test targets: re-exports ViewInspector, and points `AppDirectories.support` at a scratch folder with `AppDirectories.withTemporarySupportFolder`. |
| `devkit` | Build, relaunch and screenshot the app in the background, the iOS Simulator loop, and every check a PR needs. |
| `release-kit` | Version, bundle, sign, appcast and publish a Sparkle release to the app's Vercel Blob store, plus the release invariant checks. |
| `dyl-lint` | SwiftSyntax rules for concurrency and state bugs that shipped in these apps. `lint/swiftlint.yml` holds the regex tier. |
| `DylManifest` | Reads each app's `DylApp.toml`. |
| `web/` (`@dylkit/web`) | Each app's download site, built from its `DylApp.toml` and serving the latest release from Blob. |
| `skills/`, `rules/` | The DylKit Cursor plugin. |

## Using it in an app

To adopt DylKit, follow the `adopt-dylkit` skill (`skills/adopt-dylkit/SKILL.md`). The rest of this section is reference.

An app depends on DylKit twice, and pins it three times to the same version:

```swift
// Package.swift
.package(url: "https://github.com/dgattey/dyl-kit", from: "0.3.2"),
```

```json
// server/package.json, the tarball DylKit's release uploads
"@dylkit/web": "https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.3.2/dylkit-web-0.3.2.tgz"
```

```yaml
# .github/workflows/dylkit.yml
uses: dgattey/dyl-kit/.github/workflows/app.yml@v0.3.2
```

`dylkit_version` fails when the tarball or the workflow ref isn't the DylKit version in `Package.resolved`. A bump changes those three lines and the lockfiles; nothing is generated or synced.

Then, in the app repo:

- `DylApp.toml` describes the app. `Sources/DylManifest/DylAppManifest.swift` is the schema, and `swift run devkit checks` validates it. `apple-dev-loop` explains the `[build]`, `[bundle.info]`, `[ios.info]` and `[local-values]` keys. [Release setup](#release-setup) explains `[release] assets`, and [Dock tile plug-in](#dock-tile-plug-in) explains `[build] dock-tile-plugin`.
- Three files are copied once from `Tests/Fixtures/SampleApp/` at adoption and then belong to the app: `.github/workflows/dylkit.yml`, which runs DylKit's PR check and release and passes the app's secrets with `secrets: inherit`; `.github/pull_request_template.md`, whose Release info box and `# Release notes` section that check reads; and `.cursor/rules/changelog-release-notes.mdc`, which tells agents how to write those notes. `release_notes` in `swift run devkit checks` fails without the rule or the template section.
- A release's notes come from the merged PR's `# Release notes`, falling back to `# What changed?` only when it's missing or empty, without comments or anything after a `---` rule. They're what people read in the update dialog and on the download page, so the PR check rejects notes with file paths, code names, flags, CSS selectors, backticks or more than three bullets. `swift run release-kit notes --check --body-file <body.md>` runs the same check locally.
- `swift run devkit <command>`, `swift run release-kit <step>` and `swift run dyl-lint` run DylKit's tools from the app repo. SwiftPM builds them from the resolved dependency, so the app holds no copy of them. The site's commands are the app's own npm scripts in `server/`.
- `.swiftlint.yml` holds only the app's own `included` paths and rules, with no `parent_config`. `swift run devkit checks` finds DylKit through SwiftPM, URL or `.package(path:)` alike, and passes its `lint/swiftlint.yml` as the parent.
- `mise.toml` pins SwiftLint (`swiftlint = "<version>"` under `[tools]`). `swift run devkit checks` fails on a missing or different version, and CI installs it with `jdx/mise-action`.
- The download site is `@dylkit/web`. `withDylKit` reads `DylApp.toml` and the screenshots' sizes when Next loads its config, and Next inlines them into the build, so nothing reads them at request time. Its pages and routes are one-line re-exports, and it serves the latest release from the app's Blob store:

```ts
// next.config.ts
import { withDylKit } from "@dylkit/web/config";
export default withDylKit({});

// app/layout.tsx
export { Layout as default, metadata } from "@dylkit/web/app";

// app/page.tsx
export { Page as default } from "@dylkit/web/app";

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

An app that wants its own layout writes `app/page.tsx` from the same pieces `@dylkit/web` exports: `SitePage`, `Hero` (with its own `visual`, `title` or `lead`), `Section`, `Showcase`, `Gallery`, `Screenshot`, `DeviceFrame`, `Features` and `Feature` (with any `glyph`), and `ReleaseNotes`. The kit's CSS is in `@layer dylkit`, so the app's own CSS and CSS Modules override it without fighting specificity, and an app restyles the whole page by setting the theme tokens (`--canvas`, `--paper`, `--ink`, `--ink-muted`, `--line`, `--shadow`) on `:root`.

`server/vercel.json`'s `ignoreCommand` must watch `../DylApp.toml` too, since the build reads it: `git rev-parse --quiet --verify "$VERCEL_GIT_PREVIOUS_SHA^{commit}" && git diff --quiet "$VERCEL_GIT_PREVIOUS_SHA" HEAD -- . ../DylApp.toml`.

Sites commit no icons. Each release renders them from the app's `.icon` and uploads them to the store's `icons/`, and the icon routes serve them. dylangattey.com reads `/icon.png` (1024 px) and `/apple-touch-icon.png` (180 px, opaque), so keep those paths and sizes. `[site] favicon = "dark"` puts the dark favicon in the tab.

The dev loop and releasing are in the `apple-dev-loop` and `apple-release` skills.

### Release setup

Each app releases to its own public Vercel Blob store, `[release] assets` in `DylApp.toml`. The repo's `BLOB_READ_WRITE_TOKEN` secret lets release-kit upload, and the site reads the public URLs with no token. The store holds each release's zip under `releases/v<version>/`, and the newest release's `appcast.xml` and `release.json` at its root. The forge only gets the pushed tag. `adopt-dylkit` has the setup steps.

### Dock tile plug-in

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

This repo is a Cursor plugin (`.cursor-plugin/plugin.json`). It ships the skills and the always-applied `dylkit` rule, so every app gets one canonical copy without copying them. To use it locally, link the checkout into Cursor's local plugins:

```sh
ln -s ~/repos/dyl-kit ~/.cursor/plugins/local/dylkit
```

For cloud agents and teammates, add `dgattey/dyl-kit` to the team's plugin marketplace.

## Developing

```sh
swift build && swift test         # Tests/Fixtures/SampleApp stands in for an app
swift run dyl-lint Sources
cd web && npm ci && npm test
scripts/release-e2e.sh            # version, bundle, sign, appcast and check SampleApp with a throwaway Ed key
```

CI runs the same on every PR. Docs-only changes skip CI.

SampleApp depends on DylKit with `.package(path: "../../..")`, and SwiftPM names a path dependency after its folder, so the checkout or worktree folder must be named `dyl-kit`. Anything else fails with `unknown package 'dyl-kit'`; use a worktree path such as `/tmp/dk-<sha>/dyl-kit`.

## Releasing DylKit

Merging a PR to `main` releases DylKit like an app, minus the app. The PR's `# Release info` box picks the bump, and the `release` workflow tags the merge commit and uploads the `@dylkit/web` tarball to `releases/v<version>/` in DylKit's Blob store. The tag is the only version: `web/package.json` stays at `0.0.0`, and the plugin manifest has none, because Cursor updates plugins from the branch's commits. Apps bump the package dependency, the tarball URL and the workflow ref together. DylKit's own PRs run the same `app.yml` Release info and Release notes checks apps call, and follow the same `.cursor/rules/changelog-release-notes.mdc`.
