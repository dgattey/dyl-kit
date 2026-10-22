#!/usr/bin/env bash
# Usage: scripts/release-e2e.sh [work-dir]
# Runs a first release of Tests/Fixtures/SampleApp end to end with a throwaway Ed key: sync, version, bundle, sign,
# appcast. Then it asserts what Sparkle relies on: an enclosure on the Blob store's download for the tag (in the
# appcast and release.json), the pinned designated requirement, a strict verify of the whole bundle, and nested XPC
# services that keep Sparkle's own entitlements. It also checks the seven site icons bundle writes, and that
# recoloring the app icon changes them.
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

icons_dir="build/release/icons"
scratch="$(mktemp -d)"
for name in icon.png icon-dark.png icon-256.png icon-256-dark.png apple-touch-icon.png favicon.ico favicon-dark.ico; do
  [[ -f "$icons_dir/$name" ]] || fail "missing $icons_dir/$name"
done

square() {
  local got
  got="$(sips -g pixelWidth -g pixelHeight "$1" |
    awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "x" h }')"
  [[ "$got" == "${2}x${2}" ]] || fail "$1 is $got, expected ${2} square"
}
square "$icons_dir/icon.png" 1024
square "$icons_dir/icon-dark.png" 1024
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

! cmp -s "$icons_dir/icon.png" "$icons_dir/icon-dark.png" || fail "icon.png and icon-dark.png match"

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

echo "release e2e OK: $requirement, ${#services[@]} XPC services, 7 site icons"
