# Bound unbounded I/O in the app and the relay

Open a PR on `ojowwalker77/interlinked` that closes #35 and #37. Branch from `main` as `jonatas/bounded-io-and-timeouts`. Both issues are about resources that grow or hang without a limit: the audit log, favicon downloads, and the relay's upstream call. They are small, independent changes and belong in one PR.

## Issue #35, part 1: cap the intelligence audit log

`Interlinked/Model/IntelligenceAudit.swift`. `IntelligenceAuditStore` is `@MainActor @Observable`. `events` is never capped. Every `begin` and `finish` calls `persist()` (line 132), which re-encodes the whole array with a pretty-printing encoder and writes it synchronously on the main actor. After weeks of use each intelligence call stalls the UI on a multi-megabyte write.

- Cap `events` at a fixed count (pick a number in the low thousands and make it a named constant) and drop the oldest on insert. `load()` must apply the same cap.
- Move the encode and write off the main actor and debounce it. `BrowserHistoryStore` in `Interlinked/Model/BrowsingHistory.swift` already has a `scheduleSave` pattern with a `saveTask`; reuse that shape. Keep the atomic write and the `0o600` permissions.
- `recoverInterruptedActions` and `clear()` must still flush.
- Keep the Settings Privacy pane working: it shows `audit.events.count` and `audit.recent` in `Interlinked/Chrome/SettingsView.swift`.
- Tests: the cap holds after more inserts than the cap; a debounced write lands once for a burst of events; load after save round-trips the newest events.

## Issue #35, part 2: bound favicon downloads

`Interlinked/App/PaneHosts.swift`, `loadFavicon` (line 135). It fetches each candidate with `URLSession.shared.data(for:)` and only checks `data.count < 1_048_576` after the whole body is buffered. `timeoutInterval: 8` is an idle timeout, not a deadline. A page whose `<link rel=icon>` points at an endless stream grows memory until the tab closes.

- Reject early when `expectedContentLength` is known and over the cap.
- Stream with `URLSession.shared.bytes(for:)` and stop past 1 MB when the length is unknown.
- Add a total deadline for the whole favicon task (a few seconds), independent of the idle timeout.
- Keep the cache policy comment and behavior (`.useProtocolCachePolicy`), the icon store write, and cancellation semantics.
- Test with a local endpoint from `test-fixtures/server.py` that streams forever, and assert the task ends within the deadline without exceeding the byte cap.

## Issue #37: relay upstream timeout and unknown fields

`relay/` is a small Node service (`npm ci && npm test`). `relay/src/server.ts` wires dependencies; `relay/src/app.ts` holds `validDecision` and `createRelay`; `relay/src/app.test.ts` has the existing tests.

- `callOpenRouter` in `server.ts` (line 39) uses `fetch` with no `AbortSignal.timeout`, so a hung upstream holds the connection open. Add a timeout (around 60 seconds, as a constant) and map an abort to a 503 or 504 through the existing error path in `createRelay`.
- `validDecision` in `app.ts` checks the fields it knows and ignores the rest, so an authenticated client can pass extra OpenRouter parameters such as `stream` through. Reject bodies with unknown top-level keys, and unknown keys inside `provider` and inside each question. Keep the exact accepted shape documented in a comment next to the validator so the app and relay stay in sync.
- Tests in `app.test.ts`: an unknown top-level field returns 400; `stream: true` returns 400; a hanging upstream returns the mapped status within the timeout (use a fake `callOpenRouter` that never resolves and a short timeout injected through dependencies, so the test does not wait 60 seconds).

## Delivery

- Run the Swift tests (`xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test`) and `npm test` in `relay/`. Report failures verbatim.
- PR description: one paragraph per issue, then `Closes #35`, `Closes #37`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
