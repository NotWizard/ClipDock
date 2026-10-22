# Changelog

## 1.2.6

- Fix mouse clicks on the collapsed search icon being intercepted by the focused native text editor. The first click now expands search while preserving native editing and input-method behavior.
- Exercise search through real native window mouse events, including the first click after reopening the clipboard panel.

## 1.2.5

- Replace the flat app icon with model-generated layered cards in a tactile dock, packaged at native macOS icon sizes.
- Derive matching folded-card menu-bar template marks with distinct recording and paused variants.
- Simplify About by removing the editable update-repository field and Apply button; release checking stays configured by the app.

## 1.2.4

- Anchor the clipboard panel to the full display frame and show it above the Dock, including when the Dock is on a screen edge.
- Move the native overflow menu to the toolbar's trailing edge while preserving the centered search and Pinboard group.

## 1.2.3

- Download updates inside ClipDock with byte progress and cancellation, using Sparkle 2.10.0.
- Verify Ed25519-signed update feeds and archives before extraction, then offer Install and Relaunch.
- Keep About, the update window and the manager reminder in sync while downloading or preparing an update.
- Preserve clipboard data and preferences through installation; retry failed downloads without replacing the working app.
- Generate signed appcast.xml alongside every release archive and include Sparkle license notices.

## 1.2.2

- Fix the quick panel's search icon so one click expands and focuses the native search editor, including after opening with the global shortcut.
- Replace the first-run checklist with an optional three-step Chinese guide covering clipboard use, shortcuts, optional direct-paste permission, and privacy settings. Replay it from “使用指南…”.
- Promote an existing history entry after a successful copy or paste, without duplicating it; preserve multi-item selection order and manual Pinboard order.
- Keep the recently used card visible when reopening the panel, and strengthen light-mode onboarding text contrast.

## 1.2.1

- Derive card-header colors from the entire source app icon, using color coverage with modest saturation weighting instead of favoring center pixels.
- Combine nearby hues so gradients and red colors crossing the hue boundary remain one color family.
- Keep monochrome app icons neutral gray and ignore tiny colored badges; preserve source hue and saturation when brightening headers.
- Add regression checks for whole-icon coverage, monochrome icons, small badges, transparency, hue boundaries and readable header contrast.

## 1.2.0

- Rename the app to ClipDock, with original clipboard-and-dock artwork and separate normal/paused menu-bar marks.
- Brighter source-derived card headers with dark, readable text; stronger center weighting keeps multi-color app icons recognizable.
- Add manual GitHub Release checks in Settings → About and native menus.
- Check automatically every 24 hours while the app runs; remember the interval across relaunch and check overdue updates after wake.
- Show a small update window and a persistent update entry at the bottom of the manager sidebar. Download opens the release page for manual installation.
- Cache available updates and avoid repeated automatic prompts for the same version. Explain offline, rate-limit, invalid-release, and missing-release responses.
- Keep existing clipboard history, preferences, shortcuts and native panel interactions compatible with earlier Trove installations.
