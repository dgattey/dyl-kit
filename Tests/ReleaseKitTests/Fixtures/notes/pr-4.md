## Summary

- **Stationary non-dragged speakers during map drag (`Sources/SconeDomain/Floorplan.swift`, `Sources/SconeUI/FloorplanMapView.swift`)**:
  - Removed `dragging`, `dragX`, and `dragY` from `MapGeometryKey` and removed the `dragPoint` override from `baseDisplayPoint` so `memoizedGeometry` (`computeHubLocations` + `AcousticCurveRouter.resolveBandCollisions`) depends strictly on static floorplan/topology coordinates.
  - Non-dragged speakers and Music Hubs stay 100% stationary while dragging a speaker across the map instead of being repelled or shelf-packed away from the cursor.
  - Extracted `MapDropTarget` and `FloorplanDragHitTesting.nearestTarget(...)` into `SconeDomain` for unit testing.

- **Smooth sidebar open/close without icon crushing or floorplan jump (`Sources/SconeUI/SconeRootView.swift`, `Sources/SconeDomain/Floorplan.swift`)**:
  - Locked the sidebar inner content width to `max(geo.size.width, 230)` with `.clipped()` so `NavigationSplitView` sidebar open/close clips smoothly like a drawer instead of crushing row text to 0px and sliding icons/badges together.
  - Relaxed `AcousticCurveRouter.hasAnyBandOverlap` post-relaxation threshold (`minClearanceX = min(minGapX * 0.25, 6)`) so narrowing the detail pane when opening the sidebar stays in continuous force-relaxation instead of snapping to `deterministicShelfPack` on the final frame.

- **Larger Preset Pills Bar (`Sources/SconeUI/PresetPillsBar.swift`)**:
  - Increased preset pill height (`28/32pt` -> `34/36pt`), horizontal padding (`11/14pt` -> `14/16pt`), typography (`.footnote` `11pt` -> `.system(size: 13.5/14, weight: .semibold)`), icon sizing (`10.5/11pt` -> `12.5/13pt`), and `+` button frame (`34x34` / `36x36`).

- **Always drive Spotify on Play, prevent 60s cached buffer cutoff & `"A room did not answer"`, and preserve Spotify Connect coordinator (`Sources/SconeStore/`, `Sources/SpotifyBridge/`, `Sources/SonosProtocolBoundary/`)**:
  - Added `SpotifyDeviceMatcher`, `WebAPI.availableDevices`, `WebAPI.transferPlayback`, and `SpotifyBridge.playOnSonosGroup` so pressing Play on a `.paused` Spotify stream (`x-sonos-vli:`) or `.stopped` group wakes/resumes or transfers Spotify Connect via the Spotify Web API first, instead of sending raw UPnP `AVTransport.Play` (which previously drained Sonos's ~60s local ring buffer while Spotify stayed paused, or timed out on `Seek(REL_TIME)` with `"A room did not answer"`).
  - Updated `SonosHousehold.enqueueSpotify` to only take the `.paused` shortcut when `CurrentURI` is already `x-rincon-queue:` with existing `upNext` tracks; otherwise switch to `x-rincon-queue:` and enqueue the current track plus up to 15 upcoming `upNext` tracks (or playlist/album container).
  - Updated `SconeStore` to only call `pauseSourcePlayback()` when Spotify was actively playing (`context.isPlaying == true`) on a non-Sonos device, and updated `groupRank(for:)` so `groupEverywhere()`, `applyPreset(_:)`, and `group(member:onto:)` preserve the active Spotify Connect coordinator (`"Bedroom Speaker + 4"` -> `"Bedroom"`).
  - Increased `SOAPClient` timeout from `4s` to `8s` with 1 automatic retry on transient timeout/network errors and endpoint refresh fallback.

## Verification
- `swift test` (45 tests in 12 suites passing, including new unit tests for `FloorplanDragHitTesting`, `SpotifyDeviceMatcher`, and `SconeStore` Spotify playback/coordinator preservation).
- Packaged and verified `/Applications/Sconeos.app`.
