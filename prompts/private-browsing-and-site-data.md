# Private browsing, site-data controls, and the permission manager

Open a PR on `ojowwalker77/interlinked` that closes #19. Branch from `main` as `jonatas/private-browsing-and-site-data`. This is one issue with three features that share the same storage and permission plumbing, so they ship together.

## Current state, which differs from the issue text

- The engine is CEF (Chromium), not WebKit. `Interlinked/Chromium/InterlinkedChromium.mm` sets one global `cache_path` under a root directory (around line 815). Every page shares that profile. Ignore `WKWebsiteDataStore` in the issue.
- Permissions: `Interlinked/Model/WebsitePermissions.swift` stores camera, microphone, camera and microphone, and location decisions per origin. `OnRequestMediaAccessPermission` and `OnShowPermissionPrompt` in the `.mm` file (around lines 1825 and 1855) consult it. The Settings Sites pane (`Interlinked/Chrome/SettingsView.swift`, around line 455) already lists per-site entries with Remove and Remove All: Jev sharing grants, permission answers, and blocking exceptions. Notifications are not handled.
- AI sharing grants live in `Interlinked/Model/AIContentGrants.swift`. Favicons are cached in `Interlinked/Model/DomainIconStore.swift`. Jev decisions are cached in `Interlinked/Model/JevDecisionCache.swift`. History is `BrowserHistoryStore` in `Interlinked/Model/BrowsingHistory.swift`. The Vault no longer exists.
- Tabs and panes are created in `Interlinked/App/Workspace.swift` and hosted by `Interlinked/App/PaneHosts.swift`. Tab state is persisted by `Interlinked/Model/Session.swift`.

## Private browsing

- Create private pages on a separate `CefRequestContext` with an empty `cache_path` (in-memory) and its own cookie manager. Give `ILChromiumView` a `private` flag that picks the context at creation.
- Add "New Private Window" (⇧⌘N). Private tabs are visually distinct in the tab strip and window chrome. Use the existing `Theme.swift` palette; do not invent a new color system.
- Private tabs never enter the session file, browsing history, favicon store, Jev decision cache, or intelligence audit. Gate each store at its entry point and add a test per store.
- Jev sharing from a private tab needs an explicit per-request grant that is not persisted.
- Closing the last private tab drops the request context so its memory storage is released.

## Site-data controls

- Add a "Clear Browsing Data" command and a Settings Privacy pane section. Scopes: cookies, cache, local storage and IndexedDB, service workers. Ranges: last hour, today, everything. Also allow clearing everything for a single origin from the Sites pane entry.
- CEF has `CefCookieManager::DeleteCookies` for cookies. For cache, local storage, and service workers there is no per-origin public API, so implement "everything" by closing all browsers on the context and deleting the cache directory, then recreating the context. For per-origin and time-ranged clearing, document exactly what CEF allows and what the UI offers; do not claim a scope that is not actually cleared.
- Define and document what happens to open tabs: tabs on affected origins reload after a clear; the user is told before it happens.

## Permission manager

- Add notifications to `WebsitePermissionKind` and handle `CEF_PERMISSION_TYPE_NOTIFICATIONS` in `OnShowPermissionPrompt`.
- The Sites pane already lists and revokes camera, microphone, location, and AI sharing by origin. Extend it with notifications and make sure a revoke takes effect on open pages immediately, not just at the next prompt.
- Follow `AGENTS.md` for any in-place group changes: X button, Escape, aligned columns. App-level settings stay in the native Settings window.

## Tests

- Private data does not survive restart: write cookies and local storage in a private context, tear it down, recreate, assert empty. Use the fixture server in `test-fixtures/server.py` (see `test-fixtures/README.md`).
- Each persistent store rejects private-tab writes.
- Clear-by-range removes only what it should for cookies.
- Revoking a permission denies the next request without a prompt.

## Delivery

- Run `xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test` and report failures verbatim.
- PR description: one paragraph per feature stating what is cleared or isolated and what CEF cannot do, then `Closes #19`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
