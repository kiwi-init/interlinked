# Interlinked

A minimal macOS browser with pages that fill the window. A small Liquid Glass control holds your tabs, address, search results, and navigation. Built with SwiftUI and WebKit, with no external package dependencies.

## Run

Open `Kiwi.xcodeproj` in Xcode and press Play, or run `script/run`.

macOS 14 or later. Native Liquid Glass requires macOS 26; older versions use a translucent material.

## Browse

The favicon expands on hover. Back, forward, +, and close sit above your tabs and an editable address. Tabs balance across rows of at most five. Addresses stay on one line and widen the control as needed. At the window edge, the field scrolls horizontally.

Type an address or search words. Three Bing results appear above the input after a short pause. Click a result, or use the arrow keys and Return. Return without a selection searches Google.

Click a page icon to switch directly. Click the current page's favicon for a searchable overview with previews. Right-click a preview to rename or close its tab.

The page label stays visible while scrolling. Clicking the page dismisses open controls without swallowing the click or submitting an unfinished address. Only the current page is mounted in the window. Background pages retain their state while WebKit can throttle their rendering.

Favicons are fetched once per hostname, shared across tabs, and saved in `~/Library/Application Support/Kiwi/Favicons` for later launches. Closing or navigating away from the last tab on that hostname releases its in-memory icon and cancels any pending fetch. Failed lookups are remembered until that hostname is no longer open. Page previews are captured when you open the overview.

Tabs restore from `~/Library/Application Support/Kiwi/session.json`. Older split workspaces migrate into individual browser tabs, preserving web addresses and the selected page. Legacy terminal entries are ignored.

## Find and save

The bottom-right actions stay in fixed icon slots. Hovering an icon reveals only its label above it. **Find for me** expands horizontally into a single-row find field. Match navigation, a count, and close stay in that row. Right-click the search icon to switch between meaning search and exact text. Search status is available on hover without adding another row.

Meaning search uses Jev to select the best answer and rank existing page text by likely intent, including translations and synonyms. Extraction includes navigation links and headings so a useful destination can rank above an incidental word fragment in body text. Results highlight the original text in yellow. Searches evaluate all extracted elements without a local count or text-length cutoff; hover over the count to check coverage or errors. Changed pages invalidate stale results.

**Might need later** explicitly saves the current page's URL, metadata and selected text on this Mac. Ordinary browsing does not save pages to Vault. Search saved pages from the address field; use **Find by description** to ask Jev to rank saved excerpts. Vault stores text, not screenshots, and can be cleared in Settings.

Configure the optional Jev tools and an OpenRouter key in Settings. The key stays in macOS Keychain. Explicit meaning searches, reading checks and Vault description searches send page or saved text to OpenRouter and TypeSafe. Automatic public-page label refinement has a separate opt-in setting. Requests use the [OpenRouter decisions API](https://openrouter.ai/openapi.json) with [Jev 1.13](https://openrouter.ai/typesafe/jev-1.13), with cancellation and an in-memory cache. Exact find and local labels work without a key.

To inspect wording, click **Critical reading** in the bottom-right controls. It is also available under **Page → Critical Reading…** in the macOS menu bar. The check starts immediately, with progress on the button. Results highlight the source paragraphs in yellow. Hover or click a highlighted paragraph to see its evaluation beside the text; the note has previous/next controls. Click elsewhere to hide the note, or click **Critical reading** again to clear all annotations. It identifies possible loaded wording, emotional pressure, unsupported certainty and opinion presented as fact. It does not verify factual claims.

## Shortcuts

| Keys | Action |
| --- | --- |
| `cmd-t` | New page |
| `cmd-w` | Close tab |
| `cmd-l` | Focus address/search |
| `cmd-r` | Reload page |
| `cmd-f` | Find in page |
| `cmd-g` / `cmd-shift-g` | Next / previous match |
| `ctrl-tab` / `ctrl-shift-tab` | Next / previous tab |
| `cmd-]` / `cmd-[` | Next / previous tab |
| `ctrl-cmd-s` | All tabs |
| hold `fn` | Speak an address or search |
| `cmd-fn` | Speak a browser command, such as "new tab" |
| `escape` | Cancel editing or return to the page |
| `cmd-q` | Quit |

Voice needs microphone and speech-recognition permission, which macOS asks for the first time.

## Development

`build/Build/Products/Debug/kiwi commands` lists the local control API. For example:

```sh
build/Build/Products/Debug/kiwi state
build/Build/Products/Debug/kiwi overview show
build/Build/Products/Debug/kiwi new-tab
build/Build/Products/Debug/kiwi edit
build/Build/Products/Debug/kiwi type paper.design
build/Build/Products/Debug/kiwi commit
```

The native app is in `Kiwi/`, its control client in `KiwiControl/`, and tests in `KiwiTests/`. The internal Kiwi identifiers preserve existing sessions, Vault data, and Keychain credentials. Legacy pane types remain for session compatibility.

Run the tests with:

```sh
xcodebuild -project Kiwi.xcodeproj -scheme Kiwi -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test
```

`project.yml` defines the Xcode project. After changing it, regenerate with `xcodegen generate`. The generated project is checked in so normal builds only need Xcode. Build products and local validation output belong in the ignored `build/` directory.
