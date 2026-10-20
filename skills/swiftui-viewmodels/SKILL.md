---
name: swiftui-viewmodels
description: How to write observable state and view models in DylKit apps — @Observable on the main actor, async loading, generation guards, and testable boundaries. Use when adding or changing app state.
---

# SwiftUI view models

- `@Observable @MainActor final class`. No `ObservableObject`/`@Published` in new code (`observable_not_main_actor` and `published_write_off_main` cover the isolation mistakes).
- The view model holds display state and calls into services through protocols or closures it receives, so tests can drive it without a network.
- Loading is `async`: kick it off from `.task {}` so SwiftUI cancels it with the view. Heavy work runs off the main actor (see `swift-concurrency-io`).
- When background refreshes race, guard with a generation counter or a semantic-equality check and drop stale results instead of flickering.
- Persist only what changed, asynchronously, through the store's single writer.
- Errors become state the view can show. Never swallow them, and never fall back to fake data.
- Test behavior with fixtures: given this input, the published state is that.
