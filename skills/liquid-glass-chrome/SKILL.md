---
name: liquid-glass-chrome
description: Default window, toolbar, sidebar and tint conventions for DylKit apps using Liquid Glass on macOS and iOS. Use when building or changing app chrome, navigation, selection highlights, Settings, or the theme palette.
---

# Liquid Glass chrome

DylUI gives every app the same structure and behavior. The look is the app's. These are the defaults `AppWindow` and `SettingsView` ship with and the baseline for new chrome; an app that wants a different look passes its own toolbar style, resizability or Settings content instead.

## Structure

- macOS: `NavigationSplitView`, a unified toolbar without a title (`AppWindow`'s default `toolbarStyle`), the native sidebar toggle, and real `.toolbar` items. Avoid custom `HStack` splits, `.windowStyle(.hiddenTitleBar)`, `.ignoresSafeArea(.container, edges: .top)` on detail views, and manual traffic-light positioning.
- iOS: `TabView`, `NavigationStack`, `List`, `.toolbar`. Share views across platforms; split only where the platform idiom differs.
- Sidebar pages switch instantly, without fade transitions, and the sidebar collapses.
- Float the window toolbar over content with `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` on macOS.
- Don't put `.backgroundExtensionEffect()` on a split view's detail column. On macOS 26 it clips the detail to the safe area, leaving a solid band under the toolbar, and mirrors the detail's content into the sidebar (Saga #43).
- Settings is `SettingsWindow`: one instance, ⌘, focuses it when it's open, and it never reopens at launch. No window lookups by title (Saga #48). Its default `SettingsView` is Saga #60's layout: a full-height sidebar of badged pages under the window controls, optional section headers, and the page's badge and big title over grouped cards. Pass your own content for another layout, drawing About and Updates from `AppAbout.main` and `AppUpdater.shared`.

## Material and color

- Standard controls with glass materials. Don't stack a background platter under a toolbar item that already has one (`forced_toolbar_background` catches the common case).
- Colors come from the app's palette, never literals in views. The app's `ThemePalette` type holds its values and any extra colors, and views read it with `@Palette var palette: AppPalette`.
- The palette adapts to light and dark on its own. Never force a color scheme.
- One accent for selection. The palette's accent is the tint, so selection never shows the system blue beside it.

## Copy

- No all-caps headers, including `List` sections (add `.textCase(nil)`). Drop headers that only restate the content.
- No nested bordered boxes. Reveal destructive actions on hover.

Check both appearances as `ui-screenshot-tests` describes.
