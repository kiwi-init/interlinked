# CI, release checks, entitlement gates, and crash diagnostics

Open a PR on `ojowwalker77/interlinked` that closes #13, #14, and #38. Branch from `main` as `jonatas/release-pipeline`. All three are about the build and release pipeline: what CI runs, what a release build must contain, and how a shipped build reports failures.

## Current state

- `.github/workflows/test.yml` runs only the `InterlinkedTests` scheme on `macos-15`. Relay tests (`npm test` in `relay/`) and the deterministic browser fixtures (`test-fixtures/`, see its `README.md` and `COMPATIBILITY.md`) do not run in CI.
- `script/testflight` archives the `TestFlight` configuration, checks that the signature contains `com.apple.security.app-sandbox`, exports with `ExportOptions-TestFlight.plist`, and uploads with `asc`. The relay URL is injected as `INTERLINKED_JEV_RELAY_URL`.
- Distribution is TestFlight and the Mac App Store. The relay authenticates with an App Store signed `AppTransaction` (see `relay/README.md`), so the App Store is the production update path. No Sparkle or custom updater exists and none should be added.
- `project.yml` (xcodegen) defines the `Interlinked`, `InterlinkedTests`, and `InterlinkedUITests` targets. `Interlinked/Info.plist` is a checked-in plist (`GENERATE_INFOPLIST_FILE: NO`). The CEF helper apps are staged by `script/stage-chromium`, which copies the sample helper bundles and rewrites their `Info.plist` names.
- Entitlements: `Interlinked/Interlinked.entitlements` for development and `Interlinked/InterlinkedTestFlight.entitlements` for TestFlight. Neither contains the managed browser passkey entitlement (`com.apple.developer.web-browser.public-key-credential`). Commit `14e7857` ("Gate TestFlight on the managed passkey entitlement (#14)") claimed a gate, but the current script only checks the sandbox key. The browser engine is CEF (Chromium), not WebKit, so passkeys go through Chromium's WebAuthn stack; with the entitlement, Chromium can use iCloud Keychain passkeys, and without it, Chromium's profile authenticator with Touch ID still works.
- No crash diagnostics exist. There is no MetricKit usage in the app.

## Issue #13: CI, update path, release checks, crash diagnostics

1. CI. Extend `.github/workflows/test.yml` (or split into jobs) to run the Swift unit tests, `npm ci && npm test` in `relay/`, and the browser fixtures served by `test-fixtures/server.py`. If the fixtures need a CEF build that CI cannot download, run what is runnable and say precisely what is skipped and why in the workflow file.
2. Release job. Add a protected workflow (manual `workflow_dispatch` on `main`) that builds the `TestFlight` configuration and runs the preflight from item 3 without uploading. Signing secrets are not in the repository; the job must fail with a clear message when they are absent rather than half-succeeding.
3. Preflight script. Factor the entitlement checks out of `script/testflight` into `script/release-preflight` that takes an archived `.app` and verifies: sandbox, the managed passkey entitlement (see #14 below), the Bluetooth usage string (see #38 below), the bundle identifier `computer.interlinked`, the version and build number, and that the compiled-in relay URL is the production one. `script/testflight` calls it before export.
4. Supported versions. Define the supported macOS versions and the pinned Chromium/CEF version in one place (`docs/` or the README) and have the preflight read the deployment target from the archive to confirm it matches.
5. Crash diagnostics. Add MetricKit (`MXMetricManager`, `MXCrashDiagnostic`) collection in the app. Persist diagnostics locally under Application Support and expose an "Export diagnostics" button in the Settings Privacy pane (`Interlinked/Chrome/SettingsView.swift`, next to the activity log export). Strip anything that could carry browsing content: no URLs, page text, cookies, form data, or line text. Only symbolicated stacks, app version, OS version, and timestamps. Do not add any network upload; export is a file the user chooses to send.
6. Release checklist. Write `docs/release-checklist.md` covering entitlements, relay health (`GET /health`), compatibility gates, rollback (TestFlight build expiry and App Store phased release), and versioning. Link it from the README.

## Issue #14: passkey entitlement and release validation

- The entitlement request is tracked on the issue itself; do not invent its status. Add a section to `docs/release-checklist.md` describing the two build flavors: with the managed passkey entitlement (iCloud Keychain passkeys work on any site) and without (Chromium profile passkeys with Touch ID). Document the user-visible limitation for the second flavor.
- Make the preflight check for the entitlement configurable: it fails when a `--require-passkeys` flag is set and warns otherwise, so development and TestFlight builds without approval keep working.
- Add a manual test plan under `docs/` for passkey registration and authentication on two independent providers (for example webauthn.io and passkeys.dev), covering Touch ID success, cancellation, and fallback. This is a document, not automated tests.

## Issue #38: Bluetooth usage string in every build

Two crash reports on 2026-09-20 (17:38 and 17:49) were TCC aborts: "must contain an NSBluetoothAlwaysUsageDescription key". The key is now in `Interlinked/Info.plist` and `project.yml`.

- `git log -S NSBluetoothAlwaysUsageDescription` shows the key landed in commit `3b32671` at 17:51 -0300 on 2026-09-20, minutes after both crashes. Confirm the crash reports carry a build number older than that commit and say so in the PR.
- Determine whether the CEF helper apps need their own copy. TCC attributes a helper's Bluetooth access to the responsible process, which is the main app, and Chromium's Web Bluetooth adapter runs in the browser process. Verify by grepping the staged helper `Info.plist` files and by triggering a Web Bluetooth request (`navigator.bluetooth.requestDevice`) from a fixture page in a debug build. If a helper does need the key, add it in `script/stage-chromium` next to the existing `PlistBuddy` calls.
- The preflight script asserts the key is present in the main app and, if required, in each helper.

## Delivery

- Run the full Swift test suite and `npm test` in `relay/`. Run `script/release-preflight` against a local archive or a debug build and paste its output in the PR.
- PR description: one paragraph per issue stating what changed and what was verified, then `Closes #13`, `Closes #14`, `Closes #38`, and end with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
