# What changed?
- Strip absolute build-machine / Xcode toolchain `LC_RPATH` entries (such as `/Applications/Xcode_26.5.app/.../usr/lib/swift-6.2/macosx`) from `Contents/MacOS/Sconeos` in `scripts/build-macos.sh` before signing, so `XprotectService` does not fail on missing CI runner rpaths when assessing the bundle on user Macs.
- Clear extended attributes (`xattr -cr`) on the staged `Sconeos.app` bundle before inside-out Sparkle/app signing.
- Add the `xattr -cr /Applications/Sconeos.app` fallback snippet to the download page's first-run instructions (`server/app/page.tsx`) for MDM-managed Macs where `com.apple.systempolicy.managed` sets `DisableOverride = true` (which blocks System Settings → "Open Anyway" with `Error -60005 creating authorization`).

# Release info
- [ ] Major
- [ ] Minor
- [x] Patch
