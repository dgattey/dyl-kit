---
name: liquid-glass-chrome
description: Window, toolbar, sidebar and tint conventions for DylKit apps using Liquid Glass on macOS and iOS. Use when building or changing app chrome, navigation, selection highlights, or the theme palette.
---

# Liquid Glass chrome

## Structure

- macOS: `NavigationSplitView`, `.windowToolbarStyle(.unified(showsTitle: false))`, the native sidebar toggle, and real `.toolbar` items. No custom `HStack` splits, `.windowStyle(.hiddenTitleBar)`, `.ignoresSafeArea(.container, edges: .top)` on detail views, or manual traffic-light positioning.
- iOS: `TabView`, `NavigationStack`, `List`, `.toolbar`. Share views across platforms; split only where the platform idiom differs.
- Sidebar pages switch instantly, without fade transitions, and the sidebar collapses.
- Float the window toolbar over content with `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` on macOS.
- Don't put `.backgroundExtensionEffect()` on a split view's detail column. On macOS 26 it clips the detail to the safe area, leaving a solid band under the toolbar, and mirrors the detail's content into the sidebar (Saga #43).
- Settings is a single-instance `Window(id:)` with `.restorationBehavior(.disabled)`, opened with `openWindow(id:)`, which focuses it when it's already open. No window lookups by title (Saga #48).

## Material and color

- Standard controls with glass materials. Don't stack a background platter under a toolbar item that already has one (`forced_toolbar_background` catches the common case).
- Colors come from the app's theme palette, never literals in views.
- The palette adapts to light and dark on its own. Never force a color scheme.
- One accent for selection. Replace the system blue highlight with the palette's accent; never show both.

## Copy

- No all-caps headers, including `List` sections (add `.textCase(nil)`). Drop headers that only restate the content.
- No nested bordered boxes. Reveal destructive actions on hover.

Check both appearances as `ui-screenshot-tests` describes.
