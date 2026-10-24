# Daily-driver compatibility matrix

Record WebKit (`interlinked engine-state`) and the macOS version with every pass. Failed login, upload, download, or popup on a local fixture is a release blocker. Real-account rows need a person signed in to that service; do not put credentials in this repository.

| Surface | Login | Upload | Download | Popup / OAuth | Last WebKit | Last macOS | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Local capability index `http://127.0.0.1:8765` | Basic/Digest fixture | File chooser | Known, unknown, slow, failure | Target-blank GET/POST, script popup, delayed block | | | Automated UI tests cover chrome around these pages. Failure here blocks release. |
| Local signed-in inbox `/inbox` | Session cookie, no password field | n/a | n/a | n/a | | | Must not count as a public page for AI. |
| Local lookalike `/identity/lookalike` | n/a | n/a | n/a | n/a | | | Title says Gmail. Origin must stay the fixture host. |
| Gmail | Real account | Attachments | Attachments | OAuth consent | | | Manual. |
| Google Docs | Real account | Insert files | Export | n/a | | | Manual. |
| GitHub | Real account | Release assets, images | Source archives | OAuth apps | | | Manual. |
| Slack | Real account | Files | Files | Sign-in popup | | | Manual. |
| Common OAuth (Google, GitHub, Apple) | Real account | n/a | n/a | Redirect / popup | | | Manual. A blocked popup that breaks sign-in is a release blocker. |
| Video meeting (Meet or Zoom in the browser) | Real account | n/a | n/a | Camera / mic prompt | | | Manual. |
| One checkout flow | Real account, never commit card data | n/a | Receipt if any | Payment popup | | | Manual. Use a sandbox if the vendor has one. |

Unicode-host and HTTPS chrome are covered by `TrustedOriginTests`. The local fixture server is HTTP only, so HTTPS transport UI is unit-tested from `https://` URLs rather than loaded over TLS.
