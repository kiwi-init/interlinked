# Session state

What Interlinked restores after a quit or a crash, what it cannot restore, and why.

## The session file

`~/Library/Application Support/Interlinked/session.json`, or the path in `INTERLINKED_SESSION`. `Session` in `Interlinked/Model/Session.swift` defines it. Version 2 holds:

| Field | What it restores |
| --- | --- |
| `tabs`, `active` | Tab order, split layout, custom tab names, and the selected tab |
| `surfaces` | The address each page shows |
| `next_tab`, `next_pane`, `next_split` | Id counters, so restored ids never collide with new ones |
| `tint`, `sidebar`, `sidebar_last` | Window chrome |
| `closed` | Up to 25 recently closed tabs: URL, your name for the tab if you gave one, and when it closed. ⇧⌘T reopens the newest. |
| `scroll` | Scroll offsets of pages you scrolled, each with the URL and document title it was taken on |

Version 1 files load with an empty `closed` and `scroll` and are written back as version 2. A file from a newer version is treated like a corrupt one (below).

## Writes, quit, and crashes

`SessionWriter` writes on a background queue no more than 150 ms after the first change it sees. Selecting, reordering, opening, closing, or renaming a tab changes the session, so the file on disk trails the window by at most 150 ms. Quitting calls `Workspace.stop()`, which flushes any pending write before Chromium shuts down. A crash loses at most the last 150 ms of changes. Otherwise the previous launch's tabs, order, and selection come back.

Every successful write also writes `session.json.backup`. If `session.json` cannot be decoded at launch, it is moved to `session.json.corrupt-<milliseconds since 1970>` and the backup opens instead. The unreadable file is never overwritten. If `session.json` is missing entirely, Interlinked starts fresh and does not fall back to the backup.

## Scroll position

Interlinked samples how far the visible pages are scrolled one second after you stop scrolling or typing in the window. At the next launch the offset is put back on the page's first load only if the loaded URL and document title both match what was saved. A page that redirects, retitles itself, or has changed its title since is left at the top. This is the same `PaneHosts.restoreScrollIfNeeded` path that restores a tab discarded under memory pressure.

## Back and forward history

Not restored. After a relaunch, each tab starts a new back and forward list at its saved address.

Chromium keeps each browser's navigation entries in the browser process. CEF can read them (`CefBrowserHost::GetNavigationEntries`) and move through them (`CefBrowser::GoBack`, `GoForward`), but it has no public API to create a browser with an existing entry list. Replaying the saved addresses one by one would re-run requests, including form posts, and would still not reproduce the per-entry page state Chromium keeps. So Interlinked does not fake it. No part of the UI claims the list survives: Back is simply unavailable on a freshly restored tab, as it is on any new tab.

## Never saved

- Form values, passwords, and editable text. Only addresses, tab names, titles, and scroll offsets are written. `SessionStateTests.testSessionSchemaHoldsNoFormPasswordOrPrivateWindowState` pins the top-level keys.
- Private windows. They do not exist yet, and the schema has no field for them. When they arrive, their tabs must stay out of `tabs`, `closed`, and `scroll`.
- Browsing history. It lives in its own file, `history.json`, with its own retention and off switch in Settings > Privacy. Recently closed tabs belong to the session and are kept even when history is off.
