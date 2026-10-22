import Foundation

/// Files every app keeps byte-for-byte as DylKit ships them, so a fix lands in all three apps with the version bump.
/// `devkit sync` writes them and the `shared_files` check fails on any drift.
public enum SharedFiles {
    public struct File: Sendable {
        public let path: String
        public let contents: String
        public let executable: Bool
    }

    static let header = "Written by `devkit sync` from DylKit. Change DylKit's copy, not this one."

    public static let all: [File] = [run, prCheck, release, prTemplate]

    static let run = File(
        path: "run", contents: #"""
            #!/bin/sh
            # \#(header)
            # ./run dev <devkit args> | ./run release <release-kit args> | ./run lint [dyl-lint args]
            # Builds DylKit's tools once (cached in .build/release) and runs them directly.
            set -eu
            root=$(cd "$(dirname "$0")" && pwd)
            case "${1:-}" in
            dev) tool=devkit ;;
            release) tool=release-kit ;;
            lint) tool=dyl-lint ;;
            *)
                echo "usage: ./run dev|release|lint <args>  (./run dev --help)" >&2
                exit 2
                ;;
            esac
            shift
            swift build --package-path "$root" -c release --product "$tool" -q >&2
            export DYLKIT_ROOT="$root"
            exec "$root/.build/release/$tool" "$@"

            """#, executable: true)

    /// Runs on `synchronize` and reads the body live: the event's body is a snapshot from when it fired, so a
    /// re-run or a push after an edit would re-check stale text (Sconeos #19).
    static let prCheck = File(
        path: ".github/workflows/pr-check.yml", contents: #"""
            # \#(header)
            name: pr-check

            on:
              pull_request:
                types: [opened, edited, reopened, synchronize]

            permissions:
              pull-requests: read

            jobs:
              release-info:
                # Edits only matter when they change a Release info checkbox; contains() is case-insensitive.
                if: >-
                  github.event.action != 'edited' || (github.event.changes.body && (
                    contains(github.event.changes.body.from, '- [x] Major') != contains(github.event.pull_request.body, '- [x] Major') ||
                    contains(github.event.changes.body.from, '- [x] Minor') != contains(github.event.pull_request.body, '- [x] Minor') ||
                    contains(github.event.changes.body.from, '- [x] Patch') != contains(github.event.pull_request.body, '- [x] Patch')
                  ))
                # Job-level so skipped edit runs don't cancel an in-flight check.
                concurrency:
                  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
                  cancel-in-progress: true
                runs-on: ubuntu-latest
                timeout-minutes: 2
                steps:
                  - name: Check exactly one Release info box
                    env:
                      GH_TOKEN: ${{ github.token }}
                      PR_NUMBER: ${{ github.event.pull_request.number }}
                    # The event's body is a snapshot from when it fired, so a re-run would re-check stale text.
                    run: |
                      body="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '.body // ""')"
                      checked="$(printf '%s\n' "$body" | grep -ciE '^[[:space:]]*-[[:space:]]*\[x\][[:space:]]*(Major|Minor|Patch)\b' || true)"
                      if [ "$checked" != "1" ]; then
                        echo "::error::Check exactly one Release info box (Major, Minor or Patch); found ${checked}."
                        exit 1
                      fi
                      echo "Release info OK"

            """#, executable: false)

    /// Every app releases the same way: a merged PR plans its version from tags and its Release info box, and
    /// release-kit hands the assets to the forge, so nothing is committed to main. Releases queue without cancelling.
    static let release = File(
        path: ".github/workflows/release.yml", contents: #"""
            # \#(header)
            name: release

            on:
              pull_request:
                types: [closed]
                branches: [main]
                paths-ignore:
                  - '**.md'
                  - 'docs/**'
                  - 'server/**'
                  - 'Tests/**'
                  - '.github/**'
                  - '.cursor/**'
              workflow_dispatch:
                inputs:
                  release_type:
                    description: 'Bump type; auto reads the Release info checkbox in the merge commit'
                    required: false
                    default: auto
                    type: choice
                    options: [auto, patch, minor, major]

            permissions:
              contents: write
              pull-requests: read

            jobs:
              release:
                if: github.event_name == 'workflow_dispatch' || github.event.pull_request.merged == true
                # Job-level, so a PR closed without merging never queues behind a release.
                concurrency:
                  group: release-${{ github.repository }}
                  cancel-in-progress: false
                runs-on: macos-26
                timeout-minutes: 30
                outputs:
                  version: ${{ steps.version.outputs.version }}
                  site: ${{ steps.version.outputs.site }}
                steps:
                  - uses: actions/checkout@v4
                    with:
                      ref: ${{ github.event.pull_request.merge_commit_sha || github.sha }}
                      # Every tag plans the version, and build numbers count commits.
                      fetch-depth: 0
                  - name: Select Xcode
                    run: sudo xcode-select -s /Applications/Xcode_26.5.app/Contents/Developer
                  - uses: actions/cache@v4
                    with:
                      path: .build
                      key: swiftpm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
                      restore-keys: swiftpm-${{ runner.os }}-
                  - name: Plan the version
                    id: version
                    env:
                      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                      RELEASE_TYPE: ${{ inputs.release_type || 'auto' }}
                      PR_NUMBER: ${{ github.event.pull_request.number }}
                    run: |
                      set -o pipefail
                      ./run release version --type "$RELEASE_TYPE" ${PR_NUMBER:+--pr "$PR_NUMBER"} | tee -a "$GITHUB_OUTPUT"
                  - name: Bundle
                    run: ./run release bundle
                  - name: Sign
                    run: ./run release sign
                  - name: Appcast
                    env:
                      SPARKLE_ED_PRIVATE_KEY_BASE64: ${{ secrets.SPARKLE_ED_PRIVATE_KEY_BASE64 }}
                    run: ./run release appcast
                  - name: Publish
                    env:
                      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                    run: ./run release publish

              # Waiting for the deploy is plain polling, so it runs on ubuntu instead of billing macOS minutes.
              live-site:
                needs: release
                runs-on: ubuntu-latest
                timeout-minutes: 17
                permissions: {}
                steps:
                  - name: Wait for the site to serve the release
                    env:
                      SITE: ${{ needs.release.outputs.site }}
                      VERSION: ${{ needs.release.outputs.version }}
                    run: |
                      for _ in $(seq 60); do
                        feed="$(curl -fsSL "$SITE/appcast.xml" || true)"
                        page="$(curl -fsSL "$SITE" || true)"
                        if grep -qF "<sparkle:shortVersionString>$VERSION<" <<<"$feed" && grep -qF "Version $VERSION" <<<"$page"; then
                          echo "$SITE serves $VERSION"
                          exit 0
                        fi
                        sleep 15
                      done
                      echo "::error::$SITE didn't serve $VERSION within 15 minutes"
                      exit 1

            """#, executable: false)

    /// `ReleaseInfo` reads the notes and the one checked Release info box from the body this template starts.
    static let prTemplate = File(
        path: ".github/pull_request_template.md", contents: """
            <!-- \(header) -->
            Closes

            <!-- User-facing bullets for Sparkle's update dialog and the release. No file paths or symbol names. -->
            # Release notes

            -

            # What changed?

            -

            # Release info

            - [ ] Major
            - [ ] Minor
            - [x] Patch

            """, executable: false)

    public enum Drift: String, Sendable {
        case missing
        case differs = "differs from DylKit's copy"
        case notExecutable = "isn't executable"
    }

    /// Every shared file under `root` that isn't as DylKit ships it.
    ///
    /// - Blocking: reads files.
    public static func drift(root: URL) -> [(file: File, drift: Drift)] {
        all.compactMap { file in
            let url = root.appending(path: file.path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (file, .missing) }
            if text != file.contents { return (file, .differs) }
            if file.executable, !FileManager.default.isExecutableFile(atPath: url.path) { return (file, .notExecutable) }
            return nil
        }
    }

    /// Rewrites every drifted shared file under `root`, and returns their paths.
    ///
    /// - Blocking: reads and writes files.
    public static func sync(root: URL) throws -> [String] {
        let drifted = drift(root: root).map(\.file)
        for file in drifted {
            let url = root.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            if file.executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return drifted.map(\.path)
    }
}
