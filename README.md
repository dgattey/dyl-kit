# DylKit

The shared framework for Dylan's Mac and iOS apps (Sconeos, Saga, Gattey Photos). One copy of what each app used to copy from the others: the release pipeline, the dev loop, lint rules, runtime helpers, the download site, and the agent skills.

| Piece | What it is |
|---|---|
| `DylCore`, `DylUI`, `DylUpdates` | Runtime libraries: launch overrides, networking helpers, the palette and window/Settings shell, and Sparkle updates (inert on iOS and in dev builds). |
| `DylTestSupport` | For apps' test targets: re-exports ViewInspector, and points `AppDirectories.support` at a scratch folder with `AppDirectories.withTemporarySupportFolder`. |
| `devkit` | Build, relaunch and screenshot the app in the background, the iOS Simulator loop, and every check a PR needs. |
| `release-kit` | Version, bundle, sign, appcast and publish a Sparkle release to the app's Vercel Blob store, plus the release invariant checks. |
| `dyl-lint` | SwiftSyntax rules for concurrency and state bugs that shipped in these apps. `lint/swiftlint.yml` holds the regex tier. |
| `DylManifest` | Reads each app's `DylApp.toml`. |
| `web/` (`@dylkit/web`) | Each app's download site, built from its `DylApp.toml` and serving the latest release from Blob. |
| `skills/`, `rules/` | The DylKit Cursor plugin. |

## Using it in an app

Add the package and depend on the runtime products:

```swift
.package(url: "https://github.com/dgattey/dyl-kit", from: "0.2.0"),
```

Then, in the app repo:

- `DylApp.toml` describes the app. `Sources/DylManifest/DylAppManifest.swift` is the schema, and `./run dev checks` validates it. Beyond the name, bundle ID and release settings:
  - `[build] icon` is a committed Icon Composer `.icon` (or `icon-generator`, a script that writes one into `build/`). `[build] resources` lists the `.xcassets`, `.xcdatamodeld` and `.xcmappingmodel` the bundler compiles with `actool`, `momc` and `mapc`; the target must `exclude:` them so SwiftPM doesn't also copy them raw. `[build] site-icons` is where `./run dev icons` writes the site's favicons.
  - `[bundle.info]` merges raw Info.plist keys on macOS and iOS, and `[ios.info]` on iOS only. Strings, integers, booleans, arrays and inline tables map to plist types. Keys DylKit derives itself, such as `CFBundleIdentifier`, can't be set there. Quote keys with characters TOML doesn't allow bare: `"UISupportedInterfaceOrientations~ipad" = [...]`.
  - `[local-values]` fills Info.plist strings, such as API credentials, from a gitignored xcconfig: each key reads the environment variable, then the file, then `defaults`. `local_values_ignored` fails if the file isn't gitignored.
  - `[release] assets` is the app's public Vercel Blob store, which holds every release's zip, `appcast.xml` and `release.json` (see [Release setup](#release-setup)).
- `./run dev sync` writes the files every app shares as DylKit ships them: the `./run` shim, `.github/workflows/pr-check.yml`, `.github/workflows/release.yml` and `.github/pull_request_template.md`. DylKit's copies live in `Sources/ReleaseKit/Shared/`. `shared_files` fails when one drifts (line endings and trailing newlines don't count), so run it after bumping DylKit. In a fresh repo, `swift run devkit sync` writes the first `./run`.
- `./run dev <command>`, `./run release <step>` and `./run lint` build `devkit`, `release-kit` and `dyl-lint` once and run them. Every other mode goes to the app's own executable `scripts/run`, mode included, which sync never touches: `./run format` runs `scripts/run format`. Saga keeps `format`, `ui` and `bootstrap` there.
- `.swiftlint.yml` holds only the app's own `included` paths and rules, with no `parent_config`. `./run dev checks` finds DylKit through SwiftPM, URL or `.package(path:)` alike, and passes its `lint/swiftlint.yml` as the parent.
- `mise.toml` pins SwiftLint (`swiftlint = "<version>"` under `[tools]`). `./run dev checks` fails on a missing or different version, and CI installs it with `jdx/mise-action`.
- The download site depends on the `@dylkit/web` tarball the matching DylKit release uploaded: `"@dylkit/web": "https://<DylKit's store>.public.blob.vercel-storage.com/releases/v0.2.0/dylkit-web-0.2.0.tgz"`, the URL DylKit's release log prints. `dylkit_web_version` fails when its version isn't the DylKit version in `Package.resolved`. It serves the latest release from the app's Blob store, and refuses any feed older than the one live when the site was built:

```ts
// next.config.ts
import { withDylKit } from "@dylkit/web/config";
export default withDylKit({ transpilePackages: ["@dylkit/web"] });

// app/appcast.xml/route.ts, and app/download/macos/route.ts with downloadResponse
import { appcastResponse, loadSite } from "@dylkit/web";
const site = loadSite();
export function GET() {
  return appcastResponse(site);
}

// app/page.tsx
import { DownloadPage, latestRelease, loadSite } from "@dylkit/web";
const site = loadSite();
export default async function Home() {
  return <DownloadPage site={site} release={await latestRelease(site)} />;
}
```

The dev loop and releasing are in the `apple-dev-loop` and `apple-release` skills.

### Release setup

Every release's files go to a public Vercel Blob store, the same way whatever forge tags the release, so a private repo releases like a public one. Each app needs this once:

1. In Vercel, create a Blob store for the app with public access (Storage → Create → Blob). Its URL is `https://<store>.public.blob.vercel-storage.com`.
2. Set that URL as `assets` under `[release]` in `DylApp.toml`. release-kit uploads there and the site reads from there.
3. Add the store's read-write token to the repo's Actions secrets as `BLOB_READ_WRITE_TOKEN`. The shared `release` workflow passes it to `./run release publish`, which refuses a token for any other store before it touches that store's latest release.

The store holds each release's zip under `releases/v<version>/`, and the newest release's `appcast.xml` and `release.json` at its root. The forge only gets the pushed tag, and the merged PR's body that `version` reads with the workflow's `GITHUB_TOKEN`. There's no GitHub release.

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

CI runs the same on every PR, with the Swift steps and `release-e2e.sh` sharing one macOS runner. Docs-only changes skip CI.

## Releasing DylKit

Merging a PR to `main` releases DylKit the way its apps release, minus the app. The PR's `# Release info` box picks the bump from the latest tag, and the `pr-check` workflow requires exactly one box. `release-kit library version` plans the version, the `release` workflow stamps it into `@dylkit/web` and packs it, and `release-kit library publish` tags the merge commit and uploads the tarball to `releases/v<version>/` in DylKit's own Blob store, whose read-write token is the repo's `BLOB_READ_WRITE_TOKEN` secret. The tag is the only version: `web/package.json` stays at `0.0.0`, and the plugin manifest has none, because Cursor updates plugins from the branch's commits. Apps pick up a release by bumping their package dependency and the tarball URL together.
