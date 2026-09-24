# CI coverage, release preflight, and crash diagnostics

Open a PR on `ojowwalker77/interlinked` that closes #13 and #38 and advances #14. Branch from `main` as `jonatas/release-pipeline`. All three are about the build and release pipeline: what CI runs, what a release build must contain, and how a shipped build reports failures.

## Current state

Read these before changing anything; much of the original issue text is already done.

- `.github/workflows/test.yml` runs only the `InterlinkedTests` scheme. Relay tests (`npm test` in `relay/`) and the deterministic browser fixtures (`test-fixtures/`, see its `README.md` and `COMPATIBILITY.md`) do not run in CI.
- `.github/workflows/release.yml` (PR #60) builds on a `v1.2.3` or `v1.2.3-rc.1` tag, imports a Developer ID certificate and notarization key from secrets when present, runs `script/release`, and publishes a DMG with its SHA-256 as a GitHub release. Unsigned builds are published and labeled as such. Direct downloads have no App Store receipt, so Jev runs with the user's own OpenRouter key there.
- `script/release` archives, signs with `script/release.entitlements`, notarizes, and packages the DMG. `script/testflight` archives the `TestFlight` configuration, checks the sandbox entitlement, runs `script/assert-passkey-entitlement` (bypass with `INTERLINKED_ALLOW_MISSING_PASSKEY_ENTITLEMENT=1`), exports, and uploads with `asc`. The relay URL is injected as `INTERLINKED_JEV_RELAY_URL`.
- Passkeys (PR #49): `Interlinked/InterlinkedPasskeys.entitlements` holds the managed browser entitlement, `script/run-passkeys` builds a Debug app signed with it (its signing failure is the approval status check), and the README "Passkeys" section documents the limitation and the manual validation plan. Apple approval is still pending and is tracked on issue #14 itself.
- The deployment target is macOS 26 on Apple silicon (`project.yml`, `release.yml`). The pinned CEF build is named in `HEADER_SEARCH_PATHS` in `project.yml` and fetched by `script/bootstrap-chromium`.
- `Interlinked/Info.plist` is checked in (`GENERATE_INFOPLIST_FILE: NO`). The CEF helper apps are staged by `script/stage-chromium`, which rewrites their `Info.plist` names with `PlistBuddy`.
- No crash diagnostics exist. There is no MetricKit usage in the app.

## Issue #13: what is still missing

1. CI coverage. Extend `test.yml` to also run `npm ci && npm test` in `relay/` and the browser fixtures served by `test-fixtures/server.py`. If the fixtures need a CEF build that CI cannot download in time, cache the SDK the way `release.yml` does; if they still cannot run, say precisely what is skipped and why in the workflow file.
2. Preflight script. Add `script/release-preflight` that takes an archived or built `.app` and verifies: the sandbox entitlement for TestFlight builds, the passkey entitlement (delegating to `script/assert-passkey-entitlement` and honoring the existing bypass variable), the Bluetooth usage string (see #38), the bundle identifier `computer.interlinked`, the version and build number, the deployment target, and that the compiled-in relay URL matches the expected one for that flavor. Both `script/testflight` and `script/release` call it before export or packaging, replacing their inline checks.
3. Supported versions. Write the supported macOS version and the pinned CEF/Chromium version in `docs/release-checklist.md` and have the preflight compare the archive's deployment target against it, so bumping one without the other fails.
4. Crash diagnostics. Add MetricKit (`MXMetricManager`, `MXCrashDiagnostic`, `MXHangDiagnostic`) collection in the app. Persist diagnostics locally under Application Support and add an "Export diagnostics" button in the Settings Privacy pane (`Interlinked/Chrome/SettingsView.swift`, next to the activity log export). Strip anything that could carry browsing content: no URLs, page text, cookies, form data, or line text. Keep symbolicated stacks, app version, build number, OS version, and timestamps. Do not add any network upload; export is a file the user chooses to send.
5. Release checklist. Write `docs/release-checklist.md` covering: entitlements per flavor (TestFlight, direct download, passkeys), relay health (`GET /health`) and the expected relay URL per flavor, compatibility gates, rollback (TestFlight build expiry, pulling a GitHub release, App Store phased release), and versioning (tag format, build numbers). Add a post-release verification step: download the published DMG or TestFlight build, run `script/release-preflight` on it, and confirm the bundle identity and relay endpoint. Link the checklist from the README.

## Issue #14: what is still missing

Do not claim approval status; it is tracked on the issue. The code work left is small:

- Fold the passkey check into `script/release-preflight` (item 2 above) so both release flavors report it the same way.
- Move the manual validation plan from the README into `docs/passkey-test-plan.md` with a checklist for two independent providers (for example webauthn.io and passkeys.dev), covering registration, authentication, Touch ID success, cancellation, and fallback, and the `tccutil reset WebBrowserPublicKeyCredential` step. Leave a one-line pointer in the README.
- Leave #14 open. The PR description says `Refs #14` and lists what remains: Apple approval, then running the test plan on a build signed with the entitlement.

## Issue #38: Bluetooth usage string in every build

Two crash reports on 2026-09-20 (17:38 and 17:49) were TCC aborts: "must contain an NSBluetoothAlwaysUsageDescription key".

- `git log -S NSBluetoothAlwaysUsageDescription` shows the key landed in commit `3b32671` at 17:51 -0300 on 2026-09-20, minutes after both crashes. Confirm the crash reports carry a build number older than that commit and say so in the PR.
- Determine whether the CEF helper apps need their own copy. TCC attributes a helper's Bluetooth access to the responsible process, which is the main app, and Chromium's Web Bluetooth adapter runs in the browser process. Verify by grepping the staged helper `Info.plist` files and by triggering `navigator.bluetooth.requestDevice` from `test-fixtures/web-capabilities.html` in a debug build. If a helper does need the key, add it in `script/stage-chromium` next to the existing `PlistBuddy` calls.
- The preflight script asserts the key is present in the main app and, if required, in each helper.

## Delivery

- Run the full Swift test suite and `npm test` in `relay/`. Run `script/release-preflight` against a debug build and paste its output in the PR.
- PR description: one paragraph per issue stating what changed and what was verified, then `Closes #13`, `Closes #38`, `Refs #14`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
