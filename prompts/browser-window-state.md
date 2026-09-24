# Browser window state and keyboard defects

Open a PR on `ojowwalker77/interlinked` that closes #32 and #36. Branch from `main` as `jonatas/browser-window-state`. Both issues are about pane lifecycle and event routing in the browser window, so they share files and one PR.

## Files

- `Interlinked/App/Workspace.swift`: the `@MainActor` model. Holds `editing`, `overviewOpen`, `pageHistoryOpen`, the `keyMonitor` local event monitor (around line 1405), `escape()`, `performApplicationShortcut`, `openAddress` (line 399), `clearPane` (line 711), `dictate` (line 1305), `restoreFocus()` (line 479), and `openNativeSettings()` (around line 1538).
- `Interlinked/App/PaneHosts.swift`: per-pane `ChromiumPage` delegate. `update(_:)` (line 265) runs on every URL change and calls `assistance.committed(pane)`. `chromiumPageDidCommit` calls it again. `chromiumPageDidFinish` calls `assistance.loaded(pane, page:)`.
- `Interlinked/App/BrowserAssistance.swift`: `committed(_:)` at line 107 clears `metadata[pane]`, labels, grants, `filterResults`, and calls `closePanel()`. `loaded(_:page:)` at line 118 rebuilds state.
- `Interlinked/App/UsefulInfo.swift` mirrors the same `committed`/`loaded` pair.
- `Interlinked/Chromium/ChromiumPage.swift`: `chromiumView(_:didChange:)` forwards CEF `OnAddressChange` as `chromiumPageDidChange`. CEF fires `OnAddressChange` for `pushState` and hash navigations but does not fire `OnLoadStart`/`OnLoadEnd` for them.
- `Interlinked/Chrome/PaneLineBar.swift` already checks `hasMarkedText()` for arrow keys; the window key monitor does not.
- `Interlinked/Chrome/AssistanceView.swift` uses `@Environment(\.openSettings)` to open Settings, which is the working pattern.

## Issue #32: same-document navigations wipe page intelligence state

On a single-page app, an internal route change or `#anchor` click clears intelligence metadata, labels, grants, and filter results, and closes an open Find or Reading panel. `loaded` never follows because there is no commit, so `current` stays nil until the next full load: sharing is unavailable, find falls back to "Exact find only", reading checks are unavailable, and filtered nodes stay hidden while the count shows 0.

Fix: only call `assistance.committed` and `usefulInfo.committed` from `chromiumPageDidCommit`, not from `update(_:)`. For a URL change with no commit, keep the existing state and refresh whatever depends on the URL (the line text, favicon sync, history record) as `update` already does. If some consumer needs the new URL in `metadata[pane]`, update that field in place rather than clearing. Add a unit test in `InterlinkedTests` that drives a same-document URL change through the delegate and asserts the metadata, grants, filter results, and open panel survive, and a second test that a real commit still resets them.

## Issue #36: keyboard and focus defects

Five items. Fix all of them.

1. Command-comma. `openNativeSettings()` calls `NSApp.sendAction(Selector(("showSettingsWindow:")))`, which AppKit ignores on macOS 14 and later. Confirm at runtime that the overview and edit state are cleared but no Settings window appears. Fix by letting SwiftUI's own Settings menu item handle the key (return `false` from the shortcut handler for ⌘,) or by routing through `openSettings` the way `AssistanceView` does. Keep the side effects (close panel, clear editing, close overview) but only when Settings actually opens.
2. Escape during IME composition. The key monitor intercepts keyCode 53 whenever `editing != nil` or a panel is open, without checking for marked text, so cancelling a Japanese or Chinese candidate discards the whole edit or closes Find. Check the first responder for `hasMarkedText()` (`NSTextInputClient`) and let the event through when composition is active. Mirror the existing check in `PaneLineBar.swift`.
3. `openAddress` leaves focus nowhere. Unlike `activateTab` and `commitLine`, it never calls `restoreFocus()`, so after opening from the overview or a popup, scrolling keys do nothing until the page is clicked. Call `restoreFocus()` at the end of `openAddress`.
4. "Clear" hides a live page. `clearPane` calls `surfaces.erase(pane)`, which swaps the view to `EmptyPaneView`, but the `ChromiumPage` stays alive: audio keeps playing, and the next URL change refills the line and brings it back. Decide the pane's contract and enforce it: erasing a browser pane must stop and release its page (see `removeBrowser` in `PaneHosts.swift`, line 240) so nothing can refill it. Cover the dictation "clear" path too.
5. Stale dictation target. `dictate` uses `voice.target ?? activePane` and `target` is never cleared after a normal finish, so a later socket `dictate` can write to a closed pane and `navigate` creates a hidden orphan page for it. Clear `voice.target` when dictation finishes, and make `dictate` and `navigate` ignore panes that no longer belong to any tab.

Add unit tests for items 3, 4, and 5 in `InterlinkedTests` (see `PaneTests.swift` for the existing style). Items 1 and 2 need a runtime check; describe what you did in the PR.

## Delivery

- Follow `AGENTS.md`: Escape and the X button must restore the previous group state.
- Run `xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test` and report failures verbatim.
- PR description: one paragraph per issue, then `Closes #32`, `Closes #36`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
