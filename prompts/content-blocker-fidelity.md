# Content blocker fidelity

Open a PR on `ojowwalker77/interlinked` that closes #40, #41, and #42. Branch from `main` as `jonatas/content-blocker-fidelity`. Work in this repository without asking clarifying questions; make routine calls yourself and record them in the PR description.

## Where the blocker lives

- `blocker/` is a Rust crate (adblock-rust) exposed to the app through `blocker/interlinked_blocker.h`. `il_blocker_check` returns a verdict (`IL_ALLOW`, `IL_REWRITE`, `IL_REDIRECT`, block) plus a detail string. `il_blocker_cosmetics` returns JSON with `hide`, `exceptions`, `procedural`, `script`, and `generichide`.
- `Interlinked/Chromium/InterlinkedChromium.mm` is the CEF host. `OnBeforeResourceLoad` (search for `il_blocker_check`) applies request verdicts, including `request->SetURL(value)` for `IL_REWRITE`. `prepareBlockingForURLString:runImmediately:` (around line 1208) reads the cosmetics JSON, registers scriptlets guarded by a hostname check, and passes `hide`, `exceptions`, and `generic` to the isolated-world cosmetics script. It ignores the `procedural` key.
- `Interlinked/Resources/blocker-resources.json` is the bundled scriptlet resource set. `script/build-blocker` and `script/build-blocker-resources` produce the crate and the resources file.
- Filter lists refresh daily at runtime; scriptlet resources only change with an app release.
- `blocker/tests/real_lists.rs` runs against real lists. Read `test-fixtures/README.md` and `test-fixtures/COMPATIBILITY.md` for the deterministic page fixtures and how they are served.

## Issue #40: apply procedural cosmetic filters

The engine returns `procedural_actions` for filters such as `:has-text()`, `:upward()`, `:matches-css()`, `:min-text-length()`, `:remove()`, and `:others()`. The cosmetics script never receives them, so those ad slots stay visible.

- Pass the `procedural` array through `prepareBlockingForURLString:` into the isolated-world cosmetics script alongside `hide`.
- Implement the procedural operators in that script. Brave's `content_cosmetic.ts` is the reference; keep the implementation small and readable, one function per operator, with a MutationObserver re-run that is throttled so it does not tax heavy pages.
- Honor `exceptions` for procedural rules the same way plain hide rules honor them.
- Add a fixture page under `test-fixtures/` with elements that only a procedural rule can hide, and a test that proves they are hidden and that a sibling without the text stays visible.

## Issue #41: use the final host's rules after a cross-site redirect

The issue describes `youtu.be` to `youtube.com` redirects getting the first host's rules. Commit `97f03b4` ("Use destination blocker rules after redirects", PR #44) added `OnResourceRedirect` for the main frame, which calls `prepareBlockingForURLString:runImmediately:YES`. This landed after the issue was filed and is probably the fix.

- Verify at runtime that a server redirect from `youtu.be` to `youtube.com` (or a fixture redirect served by `test-fixtures/server.py`) registers the destination host's scriptlets and hide rules on the first document, not the second navigation.
- Add a fixture redirect and a test covering it. If the current code already passes, the test is the deliverable for this issue. If it does not, fix the mismatch at commit time and inject late.
- State the result plainly in the PR description.

## Issue #42: scriptlet updates without a release, `$removeparam`, and the Dark Page row

Three separate items.

1. Scriptlet resources. Add a remote source for `blocker-resources.json` with the bundled copy as fallback. Make the URL a build setting, the same way `INTERLINKED_JEV_RELAY_URL` is passed in `script/testflight`, so the relay or any static host can serve it. The remote file must be validated (well-formed JSON with the expected shape and a size cap) before it replaces the bundled resources, and a bad download must fall back silently. Refresh on the same daily cadence as the filter lists. Do not decide licensing: document in the PR that the remote endpoint is opt-in until the license question is settled, and leave the build setting empty by default.
2. `$removeparam`. The rewrite path is wired but the one URL tested came back unchanged. Write a test in `blocker/tests/real_lists.rs` with a parameter the bundled lists are known to strip (for example `utm_source` under the AdGuard URL Tracking list, or whichever list the crate bundles). If the engine returns `IL_REWRITE` but the URL is unchanged, trace `request->SetURL` in `OnBeforeResourceLoad` and fix it. Note that `SetURL` only takes effect when the return value is `RV_CONTINUE` and the request is not read-only; check `request->IsReadOnly()`.
3. Dark Page row. The Toolbox "Dark Page" row does nothing visible when dark mode is set to Match macOS and macOS is light. Disable the row in that state with a short explanation. The setting lives under Pages in `Interlinked/Chrome/SettingsView.swift` ("Darken pages"); the toolbox action is `.darkPages` in `Interlinked/App/Workspace.swift` (around line 947). Follow `AGENTS.md`: keep icon and label columns aligned and do not open a separate panel.

## Delivery

- Run `script/build-blocker` and the Swift tests (`xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -destination 'platform=macOS,arch=arm64' test`) and the crate tests (`cargo test` in `blocker/`). Report failures verbatim.
- Keep `AGENTS.md` rules for any UI touched.
- PR description: one paragraph per issue stating what changed and what was verified, then `Closes #40`, `Closes #41`, `Closes #42`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
