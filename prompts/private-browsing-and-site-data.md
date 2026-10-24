# Private browsing, site-data controls, and the permission manager

Open a PR on `ojowwalker77/interlinked` that closes #19. Branch from `main` as `jonatas/private-browsing-and-site-data`. This is one issue with three features that share the same storage and permission plumbing, so they ship together.

## Current state, which differs from the issue text

- The engine is WebKit. `Interlinked/WebKit/WebKitPage.swift` creates each page's `WKWebViewConfiguration` without naming a data store, so every page shares `WKWebsiteDataStore.default()`.
- Permissions: `Interlinked/Model/WebsitePermissions.swift` stores camera, microphone, camera and microphone, and location decisions per origin. The `WKUIDelegate` methods `requestMediaCapturePermissionFor` and `requestGeolocationPermissionFor` (macOS 27 only) in `WebKitPage.swift` consult it through `BrowserCoordinator` in `PaneHosts.swift`. The Settings Sites pane (`Interlinked/Chrome/SettingsView.swift`, around line 455) already lists per-site entries with Remove and Remove All: Jev sharing grants, permission answers, and blocking exceptions. Notifications are not handled.
- AI sharing grants live in `Interlinked/Model/AIContentGrants.swift`. Favicons are cached in `Interlinked/Model/DomainIconStore.swift`. Jev decisions are cached in `Interlinked/Model/JevDecisionCache.swift`. History is `BrowserHistoryStore` in `Interlinked/Model/BrowsingHistory.swift`. The Vault no longer exists.
- Tabs and panes are created in `Interlinked/App/Workspace.swift` and hosted by `Interlinked/App/PaneHosts.swift`. Tab state is persisted by `Interlinked/Model/Session.swift`.

## Private browsing

- Create private pages on one shared `WKWebsiteDataStore.nonPersistent()`. Give `WebKitPage` a `private` flag that picks the configuration's `websiteDataStore` at creation; a page cannot change stores later.
- Add "New Private Window" (⇧⌘N). Private tabs are visually distinct in the tab strip and window chrome. Use the existing `Theme.swift` palette; do not invent a new color system.
- Private tabs never enter the session file, browsing history, favicon store, Jev decision cache, or intelligence audit. Gate each store at its entry point and add a test per store.
- Jev sharing from a private tab needs an explicit per-request grant that is not persisted.
- Closing the last private tab drops the non-persistent data store so its memory storage is released.

## Site-data controls

- Add a "Clear Browsing Data" command and a Settings Privacy pane section. Scopes: cookies, cache, local storage and IndexedDB, service workers. Ranges: last hour, today, everything. Also allow clearing everything for a single origin from the Sites pane entry.
- `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` clears by time range, and `fetchDataRecords(ofTypes:)` with `removeData(ofTypes:for:)` clears per site. The types are cookies, disk and memory cache, local storage, IndexedDB, and service worker registrations. WebKit groups records by registrable domain, not by origin, so the single-site entry clears the whole site; say so in the UI and do not claim a narrower scope than is actually cleared.
- Define and document what happens to open tabs: tabs on affected origins reload after a clear; the user is told before it happens.

## Permission manager

- Notifications: check the macOS SDK for a `WKUIDelegate` hook that lets the app answer a page's notification permission request. If there is none, web notifications stay unavailable; document that instead of adding a permission kind no page can request.
- The Sites pane already lists and revokes camera, microphone, location, and AI sharing by origin. Extend it with notifications and make sure a revoke takes effect on open pages immediately, not just at the next prompt.
- Follow `AGENTS.md` for any in-place group changes: X button, Escape, aligned columns. App-level settings stay in the native Settings window.

## Tests

- Private data does not survive restart: write cookies and local storage in a private data store, release it, create a new one, assert empty. Use the fixture server in `test-fixtures/server.py` (see `test-fixtures/README.md`).
- Each persistent store rejects private-tab writes.
- Clear-by-range removes only what it should for cookies.
- Revoking a permission denies the next request without a prompt.

## Delivery

- Run `xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test` and report failures verbatim.
- PR description: one paragraph per feature stating what is cleared or isolated and what WebKit cannot do, then `Closes #19`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
