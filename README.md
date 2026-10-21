# DylKit

The shared framework for Dylan's Mac and iOS apps (Sconeos, Saga, Gattey Photos). One copy of what each app used to copy from the others: the release pipeline, the dev loop, lint rules, runtime helpers, the download site, and the agent skills.

| Piece | What it is |
|---|---|
| `DylCore`, `DylUI`, `DylUpdates` | Runtime libraries: launch overrides, networking helpers, the palette and window/Settings shell, and Sparkle updates (inert on iOS and in dev builds). |
| `devkit` | Build, relaunch and screenshot the app in the background, the iOS Simulator loop, and every check a PR needs. |
| `release-kit` | Version, bundle, sign, appcast and publish a Sparkle release with plain git, plus the release invariant checks. |
| `dyl-lint` | SwiftSyntax rules for concurrency and state bugs that shipped in these apps. `lint/swiftlint.yml` holds the regex tier. |
| `DylManifest` | Reads each app's `DylApp.toml`. |
| `web/` (`@dylkit/web`) | Each app's download site, built from its `DylApp.toml` and appcast. |
| `skills/`, `rules/` | The DylKit Cursor plugin. |

## Using it in an app

Add the package and depend on the runtime products:

```swift
.package(url: "https://github.com/dgattey/dyl-kit", from: "0.1.0"),
```

Then, in the app repo:

- `DylApp.toml` describes the app. `Sources/DylManifest/DylAppManifest.swift` is the schema, and `./run dev checks` validates it.
- A `./run` shim runs the tools: `swift build -c release --product devkit` (or `release-kit`, `dyl-lint`), then `exec .build/release/<tool>`.
- `.swiftlint.yml` holds only the app's own `included` paths and rules, with no `parent_config`. `./run dev checks` finds DylKit through SwiftPM, URL or `.package(path:)` alike, and passes its `lint/swiftlint.yml` as the parent.
- `mise.toml` pins SwiftLint (`swiftlint = "<version>"` under `[tools]`). `./run dev checks` fails on a missing or different version, and CI installs it with `jdx/mise-action`.
- The download site depends on the `@dylkit/web` tarball attached to the matching release: `"@dylkit/web": "https://github.com/dgattey/dyl-kit/releases/download/v0.1.0/dylkit-web-0.1.0.tgz"`.

The dev loop and releasing are in the `apple-dev-loop` and `apple-release` skills.

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
```

CI runs the same on every PR.

## Releasing DylKit

Bump `version` in `web/package.json` and `.cursor-plugin/plugin.json`, merge, then push a `v<version>` tag. The `release` workflow checks that the versions match the tag, packs `@dylkit/web`, and attaches the tarball to a GitHub release. Apps pick up the new version by bumping their package dependency and the tarball URL together.
