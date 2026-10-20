Closes 

# Release notes

- **Fix Sparkle update signature validation:** Pin ad-hoc signed app bundles to a bundle-identifier designated requirement (`designated => identifier "com.sconeos.SconeOS"`) so Sparkle updates succeed across builds instead of failing with code-signature error `-67050`.
- **Verify update signatures at release time:** Require `sparkle:edSignature` and cryptographically verify it against `SUPublicEDKey` in `Info.plist` during release packaging.

# What changed?

- Updated `scripts/build-macos.sh` to sign the outer `.app` bundle with `-r='designated => identifier "com.sconeos.SconeOS"'` when ad-hoc signing (`SIGN_ID == "-"`), preventing macOS from pinning the designated requirement to a single build's `cdhash` (`# designated => cdhash H"..."`).
- Updated `scripts/package-release.sh` (ported from [dgattey/saga#46](https://github.com/dgattey/saga/pull/46)) to:
  - Auto-resolve the Sparkle EdDSA private key (`SPARKLE_ED_KEY_FILE` -> `SPARKLE_ED_PRIVATE_KEY_BASE64` -> `.cert/sparkle_ed.key` / `sparkle_private.key` / `~/.config/sconeos/sparkle_ed.key`) and fail fast if missing.
  - Assert that ad-hoc signed release bundles carry `identifier "com.sconeos.SconeOS"` in their designated requirement.
  - Require `sparkle:edSignature` in the generated `appcast.xml` and cryptographically verify it over `Sconeos-${VERSION}.zip` against `SUPublicEDKey` in the built `.app`'s `Info.plist` using `openssl pkeyutl -verify`.

---

# Release info

Specify how to bump the version on merge (default: patch):
- [ ] Major (breaking / milestone release)
- [ ] Minor (new user-facing feature)
- [x] Patch (bug fix / polish / internal)
