#!/usr/bin/env bash
# Usage: scripts/release-e2e.sh [work-dir]
# Runs a first release of Tests/Fixtures/SampleApp end to end with a throwaway Ed key: version, bundle, sign,
# appcast, check. Then it asserts what Sparkle relies on: an enclosure on the forge's download for the tag (in the
# appcast and release.json), the pinned designated requirement, a strict verify of the whole bundle, and nested XPC
# services that keep Sparkle's own entitlements.
set -euo pipefail

kit="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
fail() { echo "::error::$*" >&2; exit 1; }

swift build --package-path "$kit" --product release-kit -q
swift build --package-path "$kit" --product devkit -q
release_kit="$kit/.build/debug/release-kit"

rm -rf "$work"
cp -R "$kit/Tests/Fixtures/SampleApp" "$work"
cd "$work"
sed -i '' "s|.package(path: \"../../..\")|.package(path: \"$kit\")|" Package.swift
"$kit/.build/debug/devkit" sync

# Sparkle's private key file is the base64 Ed25519 seed; SUPublicEDKey is the base64 public key.
openssl genpkey -algorithm ed25519 -out key.pem
openssl pkey -in key.pem -outform DER | tail -c 32 | base64 >ed.key
openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | base64 >sparkle-public-key.txt
rm key.pem
printf 'build/\n.build/\ned.key\n' >.gitignore
git init -q
git add -A
git -c user.name=release-e2e -c user.email=release-e2e@invalid commit -qm "Sample"

version="$("$release_kit" version --type minor | sed -n 's/^version=//p')"
"$release_kit" bundle
"$release_kit" sign
"$release_kit" appcast --ed-key-file ed.key
"$release_kit" check

repo="$(sed -n 's/^repo = "\(.*\)"/\1/p' DylApp.toml)"
download="https://github.com/$repo/releases/download/v$version/Sample-$version.zip"
grep -qF "url=\"$download\"" build/release/appcast.xml || fail "the staged appcast's enclosure isn't $download"
[[ -f build/release/release.json ]] || fail "appcast wrote no build/release/release.json"
[[ "$(plutil -extract download raw -o - build/release/release.json)" == "$download" ]] ||
  fail "release.json's download isn't $download"

bundle_id="$(sed -n 's/^bundle-id = "\(.*\)"/\1/p' DylApp.toml | head -1)"
app="$(ls -d build/release/stage/*.app)"

requirement="$(codesign -d -r- "$app" 2>&1 | grep '^designated')"
[[ "$requirement" == "designated => identifier \"$bundle_id\"" ]] || fail "designated requirement is: $requirement"
codesign --verify --strict --deep "$app" || fail "$app doesn't verify"

entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }
artifact="$(find .build/artifacts -path '*macos*' -name Sparkle.framework -type d | head -1)"
services=("$app"/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc)
[[ -e "${services[0]}" ]] || fail "no Sparkle XPC services in $app"
for service in "${services[@]}"; do
  name="$(basename "$service")"
  codesign --verify --strict "$service" || fail "$name doesn't verify"
  [[ "$(entitlements "$service")" == "$(entitlements "$artifact/Versions/B/XPCServices/$name")" ]] ||
    fail "$name lost Sparkle's entitlements"
done
for helper in Autoupdate Updater.app; do
  codesign --verify --strict "$app/Contents/Frameworks/Sparkle.framework/Versions/B/$helper" || fail "$helper doesn't verify"
done

echo "release e2e OK: $requirement, ${#services[@]} XPC services"
