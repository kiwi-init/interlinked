# Browsing history controls, session restore, and recently closed tabs

Open a PR on `ojowwalker77/interlinked` that closes #17 and #18. Branch from `main` as `jonatas/history-and-session`. Both issues are about what the browser remembers between navigations and launches, and they share `Session.swift`, `BrowsingHistory.swift`, and `Workspace.swift`.

## Current state, which differs from the issue text

- The engine is CEF (Chromium), not WebKit. Ignore the WebKit references in the issues.
- Browsing history already exists: `Interlinked/Model/BrowsingHistory.swift` has `BrowserHistoryStore` with `record`, `remove(id)`, `clear()`, a debounced `save`, a hard cap of 500 visits, and a JSON file under Application Support. `PaneHosts.update` records a visit on URL change once the page is not loading. `Workspace.pageHistoryOpen` toggles a history panel. There is no retention policy, no off switch, no deletion by origin or time range.
- The same file holds `ResearchPage` and `ResearchRelations`, which build a `JevRequest` from page titles and about paragraphs to group related pages. Check where `BrowserAssistance` and `BrowserIntelligence` call this and whether history visits ever feed it.
- Bookmarks, favorites, the Vault, and saved sites were removed on purpose. `Workspace.start()` deletes their old files and defaults (around line 500). The new tab page was redesigned in commit `e54c6a2` and simplified in `e9264fe`. Do not add bookmarks, favorites, import, or export. The PR must say these acceptance criteria from #17 were dropped by the repository owner's earlier decision and link the removing commits.
- Session persistence: `Interlinked/Model/Session.swift` stores `version`, `tabs`, `active`, counters, `surfaces`, `tint`, and sidebar widths, written through a background `SessionWriter`. `Session.read()` returns nil on any decode failure, which silently erases the last good session. No back/forward history, scroll position, or recently closed tabs are stored. `PaneHosts.restoreScrollIfNeeded` exists; read it before deciding scroll behavior.

## Issue #17: history that users control

- Retention. Replace the fixed 500-visit cap with a retention policy: a time window (default 90 days) plus a size cap, both applied on load and on record. Expose an off switch in Settings (Privacy pane, `Interlinked/Chrome/SettingsView.swift`) that stops recording and clears the store.
- Deletion. Support deleting one visit, every visit from an origin, and a time range (last hour, today, everything). Put the controls in the existing history panel (`pageHistoryOpen`) and follow `AGENTS.md`: morph the panel's group in place, with an X button and Escape restoring the previous state.
- Jev. Ensure history visits are never included in a Jev request unless the user asks for a history-based action explicitly. Add a test that the research request built from open pages contains no history-only entries.
- Tests: retention by age and by count, deletion by item, origin, and range, the off switch clearing and stopping recording, and migration from the current file format.

## Issue #18: session state and recently closed tabs

- Recently closed. Keep a bounded list (last 25) of closed tabs with URL, name, and close time, persisted in the session file. Add a "Reopen closed tab" command with ⇧⌘T and an entry in the overview or tab menu. Reopening restores the URL and name at least.
- Selected tab and order survive normal quit and crash. Verify the existing writer flushes on quit; add a periodic flush after tab changes if it does not.
- Corrupt session. When `Session.read()` fails to decode, keep the corrupt file aside (`session.json.corrupt-<timestamp>`) and load the previous good copy. Write a backup copy on every successful save so there is always one.
- Back and forward. CEF exposes navigation entries through `CefBrowserHost::GetNavigationEntries` and `CefBrowser::GoBack`/`GoForward` but has no public API to restore an entry list into a new browser. Document this in `docs/session-state.md`: URLs and names restore, back/forward do not, and say so in the UI only if a user-visible cue exists today. Do not fake it by replaying navigations.
- Scroll position. Restore only when the URL and document title match what was saved, using the existing `restoreScrollIfNeeded` path.
- Never persist form values, passwords, or private-window state (a private window does not exist yet; keep the field out of the schema).
- Bump `Session.version` and write a migration from version 1. Tests cover normal quit, forced termination (simulate by writing then reading without flush), corrupt data, and schema migration.

## Delivery

- Run `xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test` and report failures verbatim.
- PR description: one paragraph per issue, an explicit list of the #17 criteria dropped and why, then `Closes #17`, `Closes #18`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
