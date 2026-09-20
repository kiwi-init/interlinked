# Interlinked

A minimal macOS browser with pages that fill the window. A small Liquid Glass control holds your tabs, address, search results, and navigation. Built with SwiftUI and Chromium Embedded Framework (CEF).

## Run

Open `Interlinked.xcodeproj` in Xcode and press Play, or run `script/run`.

macOS 14 or later. Native Liquid Glass requires macOS 26; older versions use a translucent material.

## Browse

The favicon expands on hover. Back, forward, +, and close sit above your tabs and an editable address. Tabs balance across rows of at most five. Addresses stay on one line and widen the control as needed. At the window edge, the field scrolls horizontally.

Type an address or search words. Three Google suggestions appear above the input after a short pause. Click a suggestion, or use the arrow keys and Return. Return without a selection searches Google.

Click a page icon to switch directly. Click the current page's favicon for a searchable overview with previews. Right-click a preview to rename or close its tab.

The page label stays visible while scrolling. Clicking the page dismisses open controls without swallowing the click or submitting an unfinished address. Only the current Chromium page is mounted in the window. Background pages retain their state, while detached Chromium views stop compositing and lose focus. When macOS reports memory pressure, Interlinked pauses the oldest eligible background pages. It skips the active page and any page with playing media, an open file picker, an active download, or unsaved form work. Returning to a paused page restores its URL and scroll position.

Favicons are fetched once per hostname, shared across tabs, and saved in `~/Library/Application Support/Interlinked/Favicons` for later launches. Closing or navigating away from the last tab on that hostname releases its in-memory icon and cancels any pending fetch. Failed lookups are remembered until that hostname is no longer open. Page previews are captured when you open the overview.

Tabs restore from `~/Library/Application Support/Interlinked/session.json`. Older split workspaces migrate into individual browser tabs, preserving web addresses and the selected page. Legacy terminal entries are ignored.

Links and scripts that request a new browser window become a new Interlinked tab when Chromium reports a user gesture. Unsolicited popups are discarded.

HTTP and HTTPS links sent by macOS open in delivery order. A cold launch reuses the untouched blank page for the first link. Every remaining link opens once in a new tab, with the last delivered link active. Interlinked ignores non-web and malformed URLs.

Downloads use Chromium's macOS save dialog and appear in the top-right page actions with their origin, destination, byte progress, cancel, failure details, and Reveal in Finder. They keep running after their tab closes. Interlinked never opens a downloaded file automatically. It records an interrupted state if the app quits during a transfer.

Download completion and failure mark the top-right page actions and can use macOS notifications when enabled in Settings.

## Built-in page features

Interlinked does not load browser extensions. The features people install extensions for are part of the browser and act inside the engine.

**Ad and tracker blocking.** Chromium asks Interlinked before every network request, and Interlinked refuses the ones to known ad and tracking hosts. The host rules come from EasyList and EasyPrivacy (CC BY-SA 3.0), are downloaded on first launch, cached in Application Support, and refreshed weekly. Only host rules are used (`||host^`, with `$third-party` and `@@` exceptions); path, resource-type, and cosmetic rules are skipped, so first-party ads such as YouTube's are not blocked and empty ad slots are not hidden. The page you navigate to always loads. **Toolbox → Blocking Ads Here** turns blocking off for one site.

**Dark pages.** Sites with their own dark theme are asked for it through `prefers-color-scheme`, and Chromium's Auto Dark Mode recolors the rest while leaving images alone. Settings → Built-ins chooses Off, Match macOS appearance, or Always. **Toolbox → Dark Page** keeps one site light.

## Find and save

The bottom-right actions stay in fixed icon slots. Hovering an icon reveals only its label above it. **Find for me** expands horizontally into a single-row find field. Match navigation, a count, and close stay in that row. Right-click the search icon to switch between meaning search and exact text. Search status is available on hover without adding another row.

Meaning search uses Jev to select the best answer and rank existing page text by likely intent, including translations and synonyms. Extraction includes navigation links and headings so a useful destination can rank above an incidental word fragment in body text. Results highlight the original text in yellow. Searches evaluate all extracted elements without a local count or text-length cutoff; hover over the count to check coverage or errors. Changed pages invalidate stale results.

**Might need later** explicitly saves the current page's URL, metadata and selected text on this Mac. Ordinary browsing does not save pages to Vault. Address-field searches check saved pages automatically, try Apple Intelligence against up to six local candidates, and can fall back to Jev to rank relevant excerpts when Jev is enabled. Vault stores text, not screenshots, and can be cleared in Settings.

On supported Macs, Apple Intelligence directly generates concise page labels from bounded title, heading, site, host, summary, and breadcrumb metadata. It also handles first-pass Vault matching, related-page grouping, and short explanations for suspicious navigation through Apple's on-device Foundation Models framework. Jev remains responsible for Critical Reading, meaning search, and semantic Personal Filters; it is not used as a page-label fallback. Local development builds can use a personal OpenRouter key saved in macOS Keychain. TestFlight builds instead use Interlinked's relay and the App Store-signed app transaction, so testers never enter or receive an API key. The OpenRouter key remains on the relay. Critical reading runs automatically on public pages by default. Settings can change it to **Run only when asked**. Meaning searches and reading checks send page text to OpenRouter and TypeSafe. Exact Jev requests and their responses are cached on this Mac for five days; the cache stores a request hash rather than page text, queries, or URLs. A page-content, model, or instruction change produces a different key. Exact find and deterministic title/heading/host label fallbacks work without either model.

When AI replaces the deterministic page label with its selected label, the page handle briefly picks up a spectrum glow. Deterministic labels and names you type yourself do not trigger it.

Interlinked includes deterministic navigation checks for active-content URLs, invalid ports, embedded credentials, HTTPS downgrades, encoded hostnames, unusual ports, cross-site forms, popups, downloads, redirect chains, and misleading link text. Apple Intelligence can explain a warning from sanitized origins and deterministic warning facts, but cannot override the browser's decision.

Critical reading checks public pages after they load. It highlights source paragraphs in yellow without moving the page. Hover or click a highlighted paragraph to see its evaluation beside the text; the note has previous/next controls. Click elsewhere to hide the note. In **Run only when asked** mode, use the bottom-right **Critical reading** button or choose **Page → Critical Reading…** in the macOS menu bar. The button stays out of the way in **Always on** mode. Critical reading identifies possible loaded wording, emotional pressure, unsupported certainty, opinion presented as fact, financial interests, political bias, and text that is probably AI-generated. AI authorship, financial-interest, and political-bias classifications are pattern-based guesses. It does not verify factual claims or infer an author's intent.

Choose **Interlinked → About Interlinked** to inspect the exact Critical Reading instruction, every classification definition, the display threshold, and a plain-language account of what the browser sends to AI services and what stays on your Mac.

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
| hold `fn` | Speak an address or search |
| `cmd-fn` | Speak a browser command, such as "new tab" |
| `escape` | Cancel editing or return to the page |
| `cmd-q` | Quit |

Voice needs microphone and speech-recognition permission, which macOS asks for the first time.

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

The native app is in `Interlinked/`, its control client in `InterlinkedControl/`, and tests in `InterlinkedTests/`. Project, target, tool, storage, and Keychain identifiers use the Interlinked name. Legacy pane types remain for session compatibility.

Run the tests with:

```sh
xcodebuild -project Interlinked.xcodeproj -scheme Interlinked -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test
```

The local browser-capability fixture covers downloads, popup behavior, forms, and navigation cases:

```sh
python3 test-fixtures/server.py
```

Then open `http://127.0.0.1:8765` in Interlinked.

On memory pressure, the tab lifecycle targets 75 percent of live pages with a floor of eight on a warning, and 40 percent with a floor of three on a critical event. Protected pages stay live even when that prevents the target.

`project.yml` defines the Xcode project. After changing it, regenerate with `xcodegen generate`. The generated project is checked in so normal builds only need Xcode. Build products and local validation output belong in the ignored `build/` directory.
