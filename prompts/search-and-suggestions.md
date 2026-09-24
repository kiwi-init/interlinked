# Search provider and suggestion privacy settings

Open a PR on `ojowwalker77/interlinked` that closes #20. Branch from `main` as `jonatas/search-and-suggestions`. This issue is standalone: it touches the address line model and Settings and does not overlap the other open issues.

## Current state, which differs from the issue text

- Suggestions now come from Google, not Bing. `Interlinked/Model/Surface.swift` builds the request at line 175 (`suggestqueries.google.com/complete/search`) and the search URL at lines 194 and 298 (`www.google.com/search`). `Interlinked/Chrome/ToolbarView.swift` shows a "Google suggestions" label around line 205. The debounce and the "two or more words" trigger live in `Interlinked/App/Workspace.swift` around line 1157.
- Search-engine hosts are recognized at `Surface.swift` line 116 for line display.
- Settings live in `Interlinked/Chrome/SettingsView.swift` with `SettingsDestination` cases General, Pages, Intelligence, Sites, Privacy (in `Workspace.swift` line 19). Each pane has a keyword list for search at the top of the file.
- Open tabs, history (`BrowserHistoryStore`), and the line text are all reachable from `Workspace`.

## Build

1. Provider model. Add a `SearchProvider` enum with Google, DuckDuckGo, Bing, Brave, and Ecosia, each with a search URL template, a suggestion URL template, and a parser for that provider's suggestion JSON shape. Keep it in `Surface.swift` or a new `Interlinked/Model/SearchProvider.swift`. Store the choice in `UserDefaults` with Google as the default so current behavior does not change silently.
2. Settings. In the General pane add a "Search" section: a provider picker, a "Show suggestions from the search provider" toggle (on by default), and a "Local suggestions only" mode. When remote suggestions are on, one sentence under the toggle states that typed text is sent to the provider after a short pause. When off, the sentence says typed text stays on this Mac until Return. Add the new words to the General keyword list.
3. Suggestion source matches provider. The suggestion endpoint follows the chosen provider unless the user picks a different suggestion provider in an advanced picker. Keep the advanced picker out of the main group; a disclosure inside the same section is fine.
4. Never send sensitive text. Before any suggestion request, skip when the text parses as a URL, an IP or `localhost` address, an email address, a path, contains `@`, or looks like a token (long strings without spaces, hex or base64 runs). Put this predicate in one function with tests.
5. Local-only mode. Rank matches from open tabs and history by prefix and word match, return at most eight, and show them in the same list as remote suggestions with a distinct label. When the remote toggle is off, this is the only source.
6. Replace the hard-coded "Google suggestions" label with the provider name.

## Tests

- Disabled remote suggestions make no network request: inject a `URLProtocol` stub or a suggestion-client protocol and assert zero calls while typing.
- Each provider's suggestion parser handles a sample response and an empty response.
- The sensitive-text predicate rejects each listed class and accepts ordinary queries.
- Local-only ranking returns tab and history matches in the expected order.
- Pressing Return with a chosen provider builds that provider's search URL.

## Delivery

- Follow `AGENTS.md` for the Settings group layout: icon and label columns aligned, no detached panels.
- Run `xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test` and report failures verbatim.
- PR description: a paragraph on the provider model, a paragraph on privacy behavior, then `Closes #20`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
