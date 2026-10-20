# What changed?

- **Eliminate all untyped `JSONSerialization` / `[String: Any]` parsing**:
  - Replaced all 8 untyped `JSONSerialization` dictionary/array casts and ad-hoc JSON payloads in `SpotifyBridge/WebAPI.swift` with strongly-typed `Codable` / `Decodable` / `Encodable` models (`SpotifyCurrentlyPlayingPayload`, `SpotifyQueuePayload`, `SpotifyTrackObjectPayload`, `SpotifyDevicesPayload`, `SpotifyTransferPlaybackPayload`, `SpotifyResumePlaybackPayload`, `SpotifyTokenPayload`, `SpotifyUserProfilePayload`, `SpotifyOEmbedPayload`, `SpotifyNamedResourcePayload`).
  - Replaced untyped `JSONSerialization` array/dictionary parsing and raw string interpolation in `SonosMuseClient` (`SonosHousehold.swift`) with strongly-typed `Codable` envelope models (`PlayerInfoPayload`, `CommandHeader`, `OutboundCommandEnvelope`, `AreasResponseEnvelope`).
- **Off-main-thread I/O & deferred cryptography**:
  - Updated `TokenVault` (`WebAPI.swift`) to compute only the primary `HKDF<SHA256>` symmetric key up front and defer generating the ~30 legacy fallback key candidates to a lazy fallback path only when primary AES-GCM decryption fails.
  - Added `TokenVaultWriter` actor and `storeAsync` / `storeDisplayNameAsync` / `clearAsync` methods so `SpotifyBridge` (`@MainActor`) never blocks the main thread on AES-GCM encryption or `0600` atomic file writes.
  - Replaced `NSLock` + caller-thread synchronous file I/O + per-call `ISO8601DateFormatter` allocation in `NetworkDebugLog` (`SOAP.swift`) with a background `NetworkDebugLogWriter` actor and modern `Date().ISO8601Format(...)`.
- **Modern Swift 6 concurrency & regex**:
  - Replaced all `NSRegularExpression` and `.regularExpression` string searches across `Floorplan.swift`, `WebAPI.swift`, `Discovery.swift`, `TelemetryService.swift`, and `SpotifyOnSonos.swift` with compile-time Swift `Regex` literals (`/.../`).
  - Replaced `@unchecked Sendable` + `NSLock` in `InterruptibleSocket` and `SeenURLSet` (`Discovery.swift`) with `OSAllocatedUnfairLock` and strict `Sendable` conformance, and replaced raw `Thread` creation with `Task.detached(priority: .utility)`.
  - Replaced recursive `flatMap` array allocations in `XMLNode.descendants(_:)` (`SOAP.swift`, `TransportService.swift`, `TelemetryService.swift`, `SpotifyOnSonos.swift`) with an `inout` buffer traversal and a short-circuiting `firstDescendant(_:)` lookup.
  - Replaced `DispatchQueue.main.asyncAfter` in `SconeosMain.swift` with `Task.sleep(for: .milliseconds(150))`, and updated `SconeSettingsView` to read `CFBundleShortVersionString` dynamically from `Bundle.main`.
- **Tests**:
  - Added unit tests in `SconeDomainTests.swift` covering `SonosMuseClient` `Codable` encoding/decoding, `SconeFiles.saveAsync`, and `TokenVault` async persistence.

# Release info

- [ ] Major
- [ ] Minor
- [x] Patch
