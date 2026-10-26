#!/usr/bin/env bash
# Usage: scripts/release-e2e.sh [work-dir]
# Runs a first release of Tests/Fixtures/SampleApp end to end with a throwaway Ed key: version, bundle, sign,
# appcast. Then it asserts what Sparkle relies on: an enclosure on the Blob store's download for the tag (in the
# appcast and release.json), the pinned designated requirement, a strict verify of the whole bundle, and nested XPC
# services that keep Sparkle's own entitlements. It also checks the six site icons bundle writes, that recoloring the
# app icon changes them, that release and dev builds both carry a signed dock tile plug-in that loads, that no
# build edits a binary after it's signed, and that the iOS Simulator build carries the macOS dev build's version.
set -euo pipefail

kit="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
fail() { echo "::error::$*" >&2; exit 1; }
# Runs a build, echoing its stderr, and fails if install_name_tool edited a binary after it was signed.
unsigned_edits() {
  local log status=0
  log="$(mktemp)"
  "$@" 2>"$log" || status=$?
  cat "$log" >&2
  ((status == 0)) || exit "$status"
  if grep -F "invalidate the code signature" "$log" >/dev/null; then
    fail "$(basename "$1") $2 edited a binary after signing it"
  fi
}

swift build --package-path "$kit" --product release-kit -q
swift build --package-path "$kit" --product devkit -q
release_kit="$kit/.build/debug/release-kit"

rm -rf "$work"
cp -R "$kit/Tests/Fixtures/SampleApp" "$work"
cd "$work"
sed -i '' "s|.package(path: \"../../..\")|.package(path: \"$kit\")|" Package.swift

# Sparkle's private key file is the base64 Ed25519 seed; SUPublicEDKey is the base64 public key.
openssl genpkey -algorithm ed25519 -out key.pem
openssl pkey -in key.pem -outform DER | tail -c 32 | base64 >ed.key
openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | base64 >sparkle-public-key.txt
rm key.pem
printf 'ed.key\n' >>.gitignore
git init -q
git add -A
git -c user.name=release-e2e -c user.email=release-e2e@invalid commit -qm "Sample"

# SampleApp is the end state adopt-dylkit describes, so every check an app's PR runs passes on it.
"$kit/.build/debug/devkit" checks

version="$("$release_kit" version --type minor | sed -n 's/^version=//p')"
unsigned_edits "$release_kit" bundle

icons_dir="build/release/icons"
scratch="$(mktemp -d)"
for name in icon.png icon-256.png icon-256-dark.png apple-touch-icon.png favicon.ico favicon-dark.ico; do
  [[ -f "$icons_dir/$name" ]] || fail "missing $icons_dir/$name"
done

square() {
  local got
  got="$(sips -g pixelWidth -g pixelHeight "$1" |
    awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "x" h }')"
  [[ "$got" == "${2}x${2}" ]] || fail "$1 is $got, expected ${2} square"
}
square "$icons_dir/icon.png" 1024
square "$icons_dir/icon-256.png" 256
square "$icons_dir/icon-256-dark.png" 256
square "$icons_dir/apple-touch-icon.png" 180

cat >"$scratch/opaque.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
guard CommandLine.arguments.count == 2,
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
let w = image.width, h = image.height, row = w * 4
var pixels = [UInt8](repeating: 0, count: row * h)
pixels.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { exit(1) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}
if stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] < 255 }) { exit(1) }
SWIFT
swift "$scratch/opaque.swift" "$icons_dir/apple-touch-icon.png" || fail "apple-touch-icon.png isn't opaque"

! cmp -s "$icons_dir/icon-256.png" "$icons_dir/icon-256-dark.png" || fail "icon-256.png and icon-256-dark.png match"

for name in favicon.ico favicon-dark.ico; do
  [[ "$(head -c 4 "$icons_dir/$name" | xxd -p)" == "00000100" ]] || fail "$name isn't an ICO"
done

cp "$icons_dir/icon.png" "$icons_dir/apple-touch-icon.png" "$scratch/"
sed -i '' 's/srgb:0.60392,0.37255,0.07059,1.00000/srgb:0.20000,0.30000,0.40000,1.00000/' AppIcon.icon/icon.json
git -c user.name=release-e2e -c user.email=release-e2e@invalid commit -qam "Recolor the icon"
"$release_kit" bundle
! cmp -s "$icons_dir/icon.png" "$scratch/icon.png" || fail "icon.png is stale"
! cmp -s "$icons_dir/apple-touch-icon.png" "$scratch/apple-touch-icon.png" || fail "apple-touch-icon.png is stale"

"$release_kit" sign
"$release_kit" appcast --ed-key-file ed.key

assets="$(sed -n 's/^assets = "\(.*\)"/\1/p' DylApp.toml)"
download="$assets/releases/v$version/Sample-$version.zip"
grep -qF "url=\"$download\"" build/release/appcast.xml || fail "the staged appcast's enclosure isn't $download"
[[ -f build/release/release.json ]] || fail "appcast wrote no build/release/release.json"
[[ "$(plutil -extract download raw -o - build/release/release.json)" == "$download" ]] ||
  fail "release.json's download isn't $download"
grep -qF "\"version\" : \"$version\"" build/release/history.json || fail "history.json doesn't list $version"
grep -qF "/releases" build/release/appcast.xml || fail "the staged appcast doesn't link /releases"

uploads="$("$release_kit" publish --dry-run)"
grep -qxF "releases/v$version/Sample-$version.zip" <<<"$uploads" || fail "publish --dry-run lists: $uploads"
[[ -z "$(git tag -l "v$version")" ]] || fail "publish --dry-run tagged v$version"

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
  [[ "$(entitlements "$service")" == "$(entitlements "$artifact/Versions/B/XPCServices/$name")" ]] ||
    fail "$name lost Sparkle's entitlements"
done

plugin_name="$(plutil -extract NSDockTilePlugIn raw -o - "$app/Contents/Info.plist")" ||
  fail "$app sets no NSDockTilePlugIn"
cat >"$scratch/load.swift" <<'SWIFT'
import AppKit
guard let bundle = Bundle(path: CommandLine.arguments[1]), bundle.load(),
    let plugIn = (bundle.principalClass as? NSObject.Type)?.init() as? NSDockTilePlugIn else { exit(1) }
plugIn.setDockTile(nil)
SWIFT
swiftc -o "$scratch/load" "$scratch/load.swift"
dock_tile() {
  local plugin="$1/Contents/PlugIns/$plugin_name"
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$plugin/Contents/Info.plist")" == "$2.docktile" ]] ||
    fail "$plugin isn't $2.docktile"
  codesign --verify --deep --strict "$plugin" || fail "$plugin doesn't verify"
  "$scratch/load" "$plugin" || fail "$plugin's principal class isn't an NSDockTilePlugIn"
}
dock_tile "$app" "$bundle_id"

dev_app="$(unsigned_edits "$kit/.build/debug/devkit" build | tail -1)"
codesign --verify --strict --deep "$dev_app" || fail "$dev_app doesn't verify"
dock_tile "$dev_app" "$bundle_id.dev"

ios_app="$("$kit/.build/debug/devkit" ios | tail -1)"
for key in CFBundleShortVersionString CFBundleVersion; do
  macos_value="$(plutil -extract "$key" raw -o - "$dev_app/Contents/Info.plist")"
  ios_value="$(plutil -extract "$key" raw -o - "$ios_app/Info.plist")"
  echo "$key: macOS dev $macos_value, iOS $ios_value"
  [[ "$ios_value" == "$macos_value" ]] || fail "$ios_app's $key is $ios_value, not the dev build's $macos_value"
done

echo "release e2e OK: $requirement, ${#services[@]} XPC services, 6 site icons, $plugin_name in release and dev," \
  "iOS at the dev build's version"
