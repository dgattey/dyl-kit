---
name: swiftui-views
description: How to write SwiftUI views in DylKit apps — small value views, data in, actions out, real data only, and cheap bodies. Use when creating or refactoring a view.
---

# SwiftUI views

- A view takes the values it shows and closures for what it does. It doesn't own networking, persistence or a store reference it only reads one field from.
- Keep `body` cheap: no formatters, sorting, filtering or image decoding inside it. Precompute in the view model or a cached formatter (`formatter_alloc`).
- Use `LazyVStack`/`List` for anything that scrolls, with stable identities.
- Real data or nothing: no placeholders, demo rows, hard-coded names, rooms or counts. An empty state is a real state.
- Standard controls first; customize with the palette, not by rebuilding the control.
- `NSViewRepresentable`/`UIViewRepresentable` `update` methods compare before writing to the platform view.
- Preview with `#Preview` using fixtures from tests, never with values baked into the view.
- Split a view when its body needs a comment to navigate, not by line count.

See `liquid-glass-chrome` for chrome and copy, `swiftui-viewmodels` for state.
