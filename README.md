# Interlinked

A minimal macOS browser with pages that fill the window. A small Liquid Glass control holds your tabs, address, search results, and navigation. Built with SwiftUI and WebKit, with no external package dependencies.

## Run

Open `Interlinked.xcodeproj` in Xcode and press Play, or run `script/run`.

macOS 14 or later. Native Liquid Glass requires macOS 26; older versions use a translucent material.

## Browse

The favicon expands on hover. Back, forward, +, and close sit above your tabs and an editable address. Tabs balance across rows of at most five. Addresses stay on one line and widen the control as needed. At the window edge, the field scrolls horizontally.

Type an address or search words. Three Bing results appear above the input after a short pause. Click a result, or use the arrow keys and Return. Return without a selection searches Google.

Click a page icon to switch directly. Click the current page's favicon for a searchable overview with previews. Right-click a preview to rename or close its tab.

The page label stays visible while scrolling. Clicking the page dismisses open controls without swallowing the click or submitting an unfinished address. Only the current page is mounted in the window. Background pages retain their state while WebKit can throttle their rendering.

Favicons are fetched once per hostname, shared across tabs, and saved in `~/Library/Application Support/Interlinked/Favicons` for later launches. Closing or navigating away from the last tab on that hostname releases its in-memory icon and cancels any pending fetch. Failed lookups are remembered until that hostname is no longer open. Page previews are captured when you open the overview.

Tabs restore from `~/Library/Application Support/Interlinked/session.json`. Older split workspaces migrate into individual browser tabs, preserving web addresses and the selected page. Legacy terminal entries are ignored.

Links that open a new browser window become a new Interlinked tab. File downloads use the standard macOS save panel, starting in Downloads. Camera and microphone requests keep WebKit's per-site permission prompt.

## Find and save

The bottom-right actions stay in fixed icon slots. Hovering an icon reveals only its label above it. **Find for me** expands horizontally into a single-row find field. Match navigation, a count, and close stay in that row. Right-click the search icon to switch between meaning search and exact text. Search status is available on hover without adding another row.

Meaning search uses Jev to select the best answer and rank existing page text by likely intent, including translations and synonyms. Extraction includes navigation links and headings so a useful destination can rank above an incidental word fragment in body text. Results highlight the original text in yellow. Searches evaluate all extracted elements without a local count or text-length cutoff; hover over the count to check coverage or errors. Changed pages invalidate stale results.

**Might need later** explicitly saves the current page's URL, metadata and selected text on this Mac. Ordinary browsing does not save pages to Vault. Address-field searches check saved pages automatically and can ask Jev to rank relevant excerpts. Vault stores text, not screenshots, and can be cleared in Settings.

Local development builds can use a personal OpenRouter key saved in macOS Keychain. TestFlight builds instead use Interlinked's relay and the App Store-signed app transaction, so testers never enter or receive an API key. The OpenRouter key remains on the relay. Critical reading runs automatically on public pages by default. Settings can change it to **Run only when asked**. Meaning searches and reading checks send page text to OpenRouter and TypeSafe. Address-field searches automatically check the Vault and may send the query with relevant saved excerpts. Automatic public-page label refinement has a separate opt-in setting. Exact Jev requests and their responses are cached on this Mac for five days; the cache stores a request hash rather than page text, queries, or URLs. A page-content, model, or instruction change produces a different key. Exact find and local labels work without Jev.

When Jev replaces the local page label with its selected label, the page handle briefly picks up a spectrum glow. Local labels and names you type yourself do not trigger it.

Critical reading checks public pages after they load. It highlights source paragraphs in yellow without moving the page. Hover or click a highlighted paragraph to see its evaluation beside the text; the note has previous/next controls. Click elsewhere to hide the note. In **Run only when asked** mode, use the bottom-right **Critical reading** button or choose **Page → Critical Reading…** in the macOS menu bar. The button stays out of the way in **Always on** mode. Critical reading identifies possible loaded wording, emotional pressure, unsupported certainty, opinion presented as fact, and text that is probably AI-generated. AI authorship detection is only a pattern-based guess. It does not verify factual claims.

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
| `ctrl-tab` / `ctrl-shift-tab` | Next / previous tab |
| `cmd-]` / `cmd-[` | Next / previous tab |
| hold `cmd`, then `1`–`9` | Show other tabs and open the numbered tab |
| `ctrl-cmd-s` | All tabs |
| hold `fn` | Speak an address or search |
| `cmd-fn` | Speak a browser command, such as "new tab" |
| `escape` | Cancel editing or return to the page |
| `cmd-q` | Quit |

Voice needs microphone and speech-recognition permission, which macOS asks for the first time.

## Passkeys and Touch ID

WebKit only permits a third-party browser to use passkeys for arbitrary websites when Apple has approved the app for the managed `com.apple.developer.web-browser.public-key-credential` entitlement. The ordinary `script/run` build uses the Interlinked Apple Development identity but omits that restricted entitlement until Apple approves it.

The Account Holder must first submit Apple's [macOS browser passkey entitlement request](https://developer.apple.com/contact/request/macos-browsers-passkeys/). After Apple enables the capability for the app's Developer account, run the provisioned build with:

```sh
script/run-passkeys
```

The script stops if Xcode cannot provision that managed capability or if the signed app does not contain it. Once present, `WKWebView` handles WebAuthn challenges and macOS presents the passkey and Touch ID UI.

## Development

`build/Build/Products/Debug/interlinked commands` lists the local control API. For example:

```sh
build/Build/Products/Debug/interlinked state
build/Build/Products/Debug/interlinked overview show
build/Build/Products/Debug/interlinked new-tab
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

`project.yml` defines the Xcode project. After changing it, regenerate with `xcodegen generate`. The generated project is checked in so normal builds only need Xcode. Build products and local validation output belong in the ignored `build/` directory.
