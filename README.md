# Interlinked

A minimal macOS browser with pages that fill the window. A small Liquid Glass control holds your tabs, address, search results, and navigation. Built with SwiftUI and WebKit.

## Run

Open `Interlinked.xcodeproj` in Xcode and press Play, or run `script/run`.

macOS 14 or later. Native Liquid Glass requires macOS 26; older versions use a translucent material.

## Browse

The collapsed page handle keeps the page label and a separate trusted origin. Titles, favicons, and AI labels cannot replace the registrable domain. HTTP shows as Not Secure. Click the origin for the full URL and connection details. The favicon expands on hover. Back, forward, +, and close sit above your tabs and an editable address. Tabs balance across rows of at most five. Addresses stay on one line and widen the control as needed. At the window edge, the field scrolls horizontally.

Type an address or search words. Three Google suggestions appear above the input after a short pause. Click a suggestion, or use the arrow keys and Return. Return without a selection searches Google.

Click a page icon to switch directly. Click the current page's favicon for a searchable overview with previews. Right-click a preview to rename or close its tab.

The page label stays visible while scrolling. Clicking the page dismisses open controls without swallowing the click or submitting an unfinished address. Only the current page is mounted in the window. Background pages retain their state, while WebKit throttles their detached views and they lose focus. When macOS reports memory pressure, Interlinked pauses the oldest eligible background pages. It skips the active page and any page with playing media, an open file picker, an active download, or unsaved form work. Returning to a paused page restores its URL and scroll position.

Favicons are fetched once per hostname, shared across tabs, and saved in `~/Library/Application Support/Interlinked/Favicons` for later launches. Closing or navigating away from the last tab on that hostname releases its in-memory icon and cancels any pending fetch. Failed lookups are remembered until that hostname is no longer open. Page previews are captured when you open the overview.

Tabs restore from `~/Library/Application Support/Interlinked/session.json`. Older split workspaces migrate into individual browser tabs, preserving web addresses and the selected page. Legacy terminal entries are ignored. ⇧⌘T reopens the last of up to 25 closed tabs. A corrupt session file is kept aside and the backup from the last good save opens instead. Back and forward lists do not survive a relaunch. [docs/session-state.md](docs/session-state.md) covers what is restored and why.

Browsing history stays in `history.json` for 90 days, up to 5,000 visits. The History panel removes one visit, every visit to a site, or the last hour, today, or everything. Settings > Privacy turns history off, which also deletes it. History never goes to Jev.

Links and scripts that request a new browser window become a new Interlinked tab. WebKit offers only windows a person opened with a click; unsolicited popups are discarded. Command-click and middle-click open a link in a new tab. Mail, phone, and other non-web links open in the app that handles them after the usual warning.

HTTP and HTTPS links sent by macOS open in delivery order. A cold launch reuses the untouched blank page for the first link. Every remaining link opens once in a new tab, with the last delivered link active. Interlinked ignores non-web and malformed URLs.

Downloads ask where to save with the macOS save panel and appear in the top-right page actions with their origin, destination, byte progress, cancel, failure details, and Reveal in Finder. They keep running after their tab closes. Interlinked never opens a downloaded file automatically. It records an interrupted state if the app quits during a transfer.

Download completion and failure mark the top-right page actions and can use macOS notifications when enabled in Settings.

## Built-in page features

Interlinked does not load browser extensions. The features people install extensions for are part of the browser and act inside the engine.

**Ad and tracker blocking.** Interlinked embeds Brave's `adblock` engine (`blocker/`, Rust, MPL-2.0) and feeds it uBlock Origin's filter lists, EasyList, EasyPrivacy, and Peter Lowe's list, refreshed daily and cached as a serialized engine in Application Support. It acts in four places:

- *Requests.* The engine converts the lists' network rules (paths, resource types, third-party, exceptions) into WebKit content rule lists, which WebKit compiles once per refresh, keeps between launches, and applies to every request itself. The page you navigate to always loads.
- *Stand-ins.* WebKit cannot answer a request with a replacement, so rules that would swap a script for a harmless stand-in are left out instead of becoming blocks, and the scripts pages depend on keep loading.
- *Tracking parameters.* `$removeparam` rules strip further parameters the lists name from page and frame addresses. WebKit cannot rewrite other requests.
- *In the page.* Before a document's own scripts run, Interlinked registers that site's scriptlets in the page's world (this is what removes video ads) and its element-hiding rules in an isolated world the page cannot see. Procedural rules (`:has-text()`, `:upward()`, `:matches-css()`, `:min-text-length()`, `:xpath()`, and the `:remove()`, `:style()`, `:remove-attr()`, `:remove-class()` actions) run in that world too, and run again as the page changes, at most every 250 ms. The page's class names and ids are matched against generic hiding rules as the DOM changes.

**Tracking parameters.** Every page and frame address loses its tracking parameters before WebKit loads it, including the destination of a server redirect, which restarts at the clean address, even with blocking off. That covers `utm_*`, ad click identifiers (`gclid`, `gbraid`, `wbraid`, `fbclid`, `msclkid`, `ttclid`, `twclid`, `yclid`, and others), and email and marketing tags (Mailchimp, HubSpot, Marketo, Klaviyo, Matomo, and others). YouTube and Spotify lose `si`, and X loses its share parameters. Other parameters keep their exact order and encoding. The list lives in `blocker/src/tracking.rs`.

`script/build-blocker-resources` converts uBlock Origin's scriptlets and redirect resources (GPL-3.0) into `Interlinked/Resources/blocker-resources.json`; rerun it to pick up new scriptlets. A build can also name an HTTPS copy of that file with `INTERLINKED_BLOCKER_RESOURCES_URL`. It is downloaded with the daily list refresh and used once it is well-formed JSON of the expected shape and under 8 MB; otherwise the bundled copy stays. The setting is empty by default and stays opt-in until the license question for serving uBlock Origin's resources is settled.

**Dark pages.** Sites with their own dark theme are asked for it through `prefers-color-scheme`. A page whose own background stays light is inverted instead, with images and video turned back, and checked again as it changes. Settings → Built-ins chooses Off, Match macOS appearance, or Always.

## Find

The bottom-right actions stay in fixed icon slots. Hovering an icon reveals only its label above it. **Find for me** expands horizontally into a single-row find field. Match navigation, a count, and close stay in that row. Right-click the search icon to switch between meaning search and exact text. Search status is available on hover without adding another row.

Meaning search uses Jev to score a local shortlist of page elements by likely intent, including translations and synonyms, then pick a first result among the strongest scores. Extraction includes navigation links and headings so a useful destination can rank above an incidental word fragment in body text. Results highlight the original text in yellow. Hover over the count to check coverage or errors. Changed pages invalidate stale results.

On supported Macs, Apple Intelligence generates one tab label from bounded title, heading, site, host, summary, and breadcrumb metadata. Labels are cached on this Mac for five days. Jev is responsible for meaning search. It is not used as a page-label fallback. Local development builds can use a personal OpenRouter key saved in macOS Keychain. TestFlight builds instead use Interlinked's relay and the App Store-signed app transaction, so testers never enter or receive an API key. The OpenRouter key remains on the relay. Interlinked does not try to detect whether you are signed in. The sharing prompt warns that a signed-in page's text is sent like any other. Form fields and editable text are never extracted. Meaning searches send page text to OpenRouter and TypeSafe. Exact Jev requests and their responses are cached on this Mac for five days; the cache stores a request hash rather than page text, queries, or URLs. A page-content, model, or instruction change produces a different key. Exact find and deterministic title/heading/host label fallbacks work without either model.

When AI replaces the deterministic page label with its selected label, the page handle briefly picks up a spectrum glow. Deterministic labels and names you type yourself do not trigger it.

Interlinked includes deterministic navigation checks for active-content URLs, invalid ports, embedded credentials, HTTPS downgrades, encoded hostnames, unusual ports, cross-site forms, popups, downloads, redirect chains, and misleading link text.

Choose **Interlinked → About Interlinked** for a plain-language account of what the browser sends to AI services and what stays on your Mac.

## Shortcuts

| Keys | Action |
| --- | --- |
| `cmd-t` | New page |
| `cmd-w` | Close tab |
| `cmd-l` | Focus address/search |
| `cmd-r` | Reload page |
| `cmd-f` | Find in page |
| `cmd-g` / `cmd-shift-g` | Next / previous match |
| `cmd-j` | Downloads |
| `ctrl-tab` / `ctrl-shift-tab` | Next / previous tab |
| `cmd-]` / `cmd-[` | Next / previous tab |
| hold `cmd`, then `1`–`9` | Show other tabs and open the numbered tab |
| `ctrl-cmd-s` | All tabs |
| `escape` | Cancel editing or return to the page |
| `cmd-q` | Quit |

## Passkeys

Pages render with WebKit, so WebAuthn goes through the system's passkey UI. Full passkey support has one remaining gate:

- **Apple approval (requested, pending).** iCloud Keychain passkeys for arbitrary sites need the managed `com.apple.developer.web-browser.public-key-credential` entitlement. Until Apple enables it for this team, signed builds cannot create or use iCloud Keychain passkeys, and `script/testflight` stops with instructions instead of shipping without them (`INTERLINKED_ALLOW_MISSING_PASSKEY_ENTITLEMENT=1` bypasses the gate for emergency releases only).
- **What works without it.** Ordinary `script/run` builds stay entitlement-free on purpose. WebKit limits WebAuthn in those builds; the fixture's Passkeys probe shows what is available.

To check any bundle: `script/assert-passkey-entitlement /path/to/Interlinked.app`. To build the provisioned variant once Apple approves: `script/run-passkeys` (signs with `Interlinked/InterlinkedPasskeys.entitlements`); while approval is pending, its signing failure is the status check.

Manual validation (issue #14): register and authenticate on at least two independent providers, covering Touch ID success, cancellation, and fallback. The local fixture (`python3 test-fixtures/server.py`, then `http://127.0.0.1:8765`) has a Passkeys probe for platform-authenticator and conditional-mediation availability without needing a real ceremony. First use also needs the macOS grant under System Settings → Passkeys Access for Web Browsers (`tccutil reset WebBrowserPublicKeyCredential` resets it).

## Development

`build/Build/Products/Debug/interlinked commands` lists the local control API. For example:

```sh
build/Build/Products/Debug/interlinked state
build/Build/Products/Debug/interlinked overview show
build/Build/Products/Debug/interlinked new-tab
build/Build/Products/Debug/interlinked open-url https://example.com
build/Build/Products/Debug/interlinked edit
build/Build/Products/Debug/interlinked type paper.design
build/Build/Products/Debug/interlinked commit
```

The native app is in `Interlinked/`, its control client in `InterlinkedControl/`, unit tests in `InterlinkedTests/`, and UI tests in `InterlinkedUITests/`. Project, target, tool, storage, and Keychain identifiers use the Interlinked name. Legacy pane types remain for session compatibility.

Run the tests with:

```sh
xcodebuild -project Interlinked.xcodeproj -scheme InterlinkedTests -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' test
```

UI tests launch the app against the local fixture server. The Interlinked scheme starts the fixture server before testing and stops it afterwards with `script/fixture-server`, because the sandboxed test runner cannot start it. Quit any other Interlinked instance first: a second app would share its session and control socket.

```sh
xcodebuild -project Interlinked.xcodeproj -scheme Interlinked -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  -only-testing:InterlinkedUITests test
```

The local browser-capability fixture covers downloads, popup behavior, forms, navigation, identity lookalikes, a signed-in inbox, WebSockets, and service workers:

```sh
python3 test-fixtures/server.py
```

Then open `http://127.0.0.1:8765` in Interlinked.

On memory pressure, the tab lifecycle targets 75 percent of live pages with a floor of eight on a warning, and 40 percent with a floor of three on a critical event. Protected pages stay live even when that prevents the target.

`project.yml` defines the Xcode project. After changing it, regenerate with `xcodegen generate`. The generated project is checked in so normal builds only need Xcode. The content blocker engine in `blocker/` is built by a pre-build step and needs Rust (`brew install rust`). Build products and local validation output belong in the ignored `build/` directory.
