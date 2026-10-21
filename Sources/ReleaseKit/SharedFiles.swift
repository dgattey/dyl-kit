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

    public static let all: [File] = [run, prBody, prCheck]

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

    static let prBody = File(
        path: "ci/github/pr-body.sh", contents: #"""
            #!/usr/bin/env bash
            # \#(header)
            # Usage: ci/github/pr-body.sh <merge-commit-sha> <out-file>
            # Writes the body of the GitHub PR that produced the commit to <out-file>, for `release-kit version
            # --pr-body-file`. When the lookup fails it leaves the file empty and release-kit falls back to the merge
            # commit message. This is the only GitHub-specific release step.
            set -uo pipefail

            sha="$1"
            out="$2"
            : >"$out"

            response="$(curl -fsSL --max-time 20 \
              -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
              -H "Accept: application/vnd.github+json" \
              "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}/commits/$sha/pulls")" || {
              echo "::warning::couldn't look up the PR for $sha; release-kit will read the merge commit message"
              exit 0
            }

            jq -r --arg sha "$sha" '(map(select(.merge_commit_sha == $sha)) + .)[0].body // empty' <<<"$response" >"$out" || : >"$out"
            if [[ -s "$out" ]]; then
              echo "read the PR body for $sha"
            else
              echo "::warning::no PR body for $sha; release-kit will read the merge commit message"
            fi

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

    /// Writes every shared file under `root`, and returns the paths it changed.
    ///
    /// - Blocking: reads and writes files.
    public static func sync(root: URL) throws -> [String] {
        var changed: [String] = []
        for file in all {
            let url = root.appending(path: file.path)
            if (try? String(contentsOf: url, encoding: .utf8)) != file.contents {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
                changed.append(file.path)
            }
            if file.executable, !FileManager.default.isExecutableFile(atPath: url.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                if !changed.contains(file.path) { changed.append(file.path) }
            }
        }
        return changed
    }
}
