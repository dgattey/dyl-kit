Closes 

# Release notes

- **One-click Spotify transfer:** When Spotify is playing on your computer or phone and a Sonos group is idle, Sconeos now shows the active track, artwork, and device (`Playing on This computer`) with a **▶ Play here** button to transfer playback directly to the group.
- **Fix stale "Playing from Spotify" state:** Idle Sonos groups no longer get stuck showing a blank placeholder with "Playing from Spotify" after Spotify Connect moves to another device.

# What changed?

- **Root Cause & Sonos Transport Parsing (`Sources/SonosProtocolBoundary/TransportService.swift`, `Sources/SonosProtocolBoundary/SpotifyOnSonos.swift`)**: When Spotify Connect transfers away from Sonos, the Sonos group coordinator remains in `PAUSED_PLAYBACK` on a hollow `x-sonos-vli:...` container (`TrackMetaData = NOT_IMPLEMENTED`, `CurrentURIMetaData = <dc:title>Spotify</dc:title>`). `TransportService.parsePlayback` now treats paused sessions with no track title, no stream content, and no Spotify track URI as `.stopped` rather than a ghost paused "Spotify" session. `SpotifyOnSonos` also handles HTML-escaped `&amp;` query separators and `spotify%3A` URIs, and falls back cleanly when `SystemProperties` is unsupported.
- **External Spotify Session Projection (`Sources/SconeDomain/Spotify.swift`, `Sources/SconeDomain/Household.swift`, `Sources/SpotifyBridge/WebAPI.swift`, `Sources/SconeStore/SconeState.swift`, `Sources/SconeStore/SconeStore.swift`)**: Polls Spotify's `/v1/me/player` even when Sonos groups are idle (at a lightweight 5s cadence with cached fallback), captures `device.type` (`Computer`, `Smartphone`, `Speaker`), formats friendly device labels (`Playing on This computer` for local Macs), and exposes `state.externalSpotify`.
- **One-Click Transfer & Sonos Queue Handoff (`Sources/SpotifyBridge/SpotifyBridge.swift`, `Sources/SconeStore/SconeStore.swift`)**: Clicking **▶ Play here** on the map hub card, bottom Now Playing bar, or Group Detail view transfers playback via `PUT /v1/me/player` (`play: true`) when any room in the group is visible in Spotify's `/v1/me/player/devices`, or seamlessly wakes the group via `enqueueAndPlaySpotify` at the current track position and pauses computer playback—without throwing `"A room did not answer"`.
- **UI Polish (`Sources/SconeUI/FloorplanMapView.swift`, `Sources/SconeUI/NowPlayingDockView.swift`, `Sources/SconeUI/GroupDetailView.swift`)**: Displays the active external Spotify track, artwork, and `Playing on This computer` badge alongside a highlighted gold **▶ Play here** action.
- **Tests (`Tests/SconeKitTests/SconeDomainTests.swift`)**: Added `dormantSpotifyConnectVLIAndExternalComputerPlaybackTransferToGroup` covering dormant `x-sonos-vli` parsing, device label projection, Connect transfer across member rooms, and fallback queue handoff + source pause.

---

# Release info

Specify how to bump the version on merge (default: patch):
- [ ] Major (breaking / milestone release)
- [x] Minor (new user-facing feature)
- [ ] Patch (bug fix / polish / internal)
