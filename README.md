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

Add the package and depend on the runtime products:

```swift
.package(url: "https://github.com/dgattey/dyl-kit", from: "0.2.0"),
```

Then, in the app repo:

- `DylApp.toml` describes the app. `Sources/DylManifest/DylAppManifest.swift` is the schema, and `./run dev checks` validates it. `apple-dev-loop` explains the `[build]`, `[bundle.info]`, `[ios.info]` and `[local-values]` keys. [Release setup](#release-setup) explains `[release] assets`, and [Dock tile plug-in](#dock-tile-plug-in) explains `[build] dock-tile-plugin`.
- `./run dev sync` writes the files every app shares as DylKit ships them: the `./run` shim, `.github/workflows/pr-check.yml`, `.github/workflows/release.yml` and `.github/pull_request_template.md`. DylKit's copies live in `Sources/ReleaseKit/Shared/`. `shared_files` fails when one drifts, so run it after bumping DylKit. In a fresh repo, `swift run devkit sync` writes the first `./run`.
- `./run dev <command>`, `./run release <step>` and `./run lint` build `devkit`, `release-kit` and `dyl-lint` once and run them. Every other mode goes to the app's own executable `scripts/run`, mode included, which sync never touches. `./run format` runs `scripts/run format`.
- `.swiftlint.yml` holds only the app's own `included` paths and rules, with no `parent_config`. `./run dev checks` finds DylKit through SwiftPM, URL or `.package(path:)` alike, and passes its `lint/swiftlint.yml` as the parent.
- `mise.toml` pins SwiftLint (`swiftlint = "<version>"` under `[tools]`). `./run dev checks` fails on a missing or different version, and CI installs it with `jdx/mise-action`.
- The download site depends on the `@dylkit/web` tarball the matching DylKit release uploaded: `"@dylkit/web": "https://frmtw5gxqbom2ooh.public.blob.vercel-storage.com/releases/v0.2.0/dylkit-web-0.2.0.tgz"`, the URL DylKit's release log prints. `dylkit_web_version` fails when its version isn't the DylKit version in `Package.resolved`. It serves the latest release from the app's Blob store:

```ts
// next.config.ts
export default { transpilePackages: ["@dylkit/web"] };

// app/appcast.xml/route.ts, and app/download/macos/route.ts with downloadResponse
import { appcastResponse, loadSite } from "@dylkit/web";
const site = loadSite();
export function GET() {
  return appcastResponse(site);
}

// app/icons/[name]/route.ts, and the same in app/icon.png/, app/apple-touch-icon.png/ and app/favicon.ico/
import { iconResponse, loadSite } from "@dylkit/web";
const site = loadSite();
export function GET(request: Request) {
  return iconResponse(site, request);
}

// app/page.tsx
import { DownloadPage, latestRelease, loadSite } from "@dylkit/web";
const site = loadSite();
export default async function Home() {
  return <DownloadPage site={site} release={await latestRelease(site)} />;
}
```

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

This repo is a Cursor plugin (`.cursor-plugin/plugin.json`). It ships the skills and the always-applied `dylkit` rule, so every app gets one canonical copy without a sync step. To use it locally, link the checkout into Cursor's local plugins:

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

## Releasing DylKit

Merging a PR to `main` releases DylKit like an app, minus the app. The PR's `# Release info` box picks the bump, and the `release` workflow tags the merge commit and uploads the `@dylkit/web` tarball to `releases/v<version>/` in DylKit's Blob store. The tag is the only version: `web/package.json` stays at `0.0.0`, and the plugin manifest has none, because Cursor updates plugins from the branch's commits. Apps bump their package dependency and the tarball URL together.
