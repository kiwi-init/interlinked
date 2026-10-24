# Browser capability fixtures

Run:

```sh
python3 test-fixtures/server.py
```

Open `http://127.0.0.1:8765` in Interlinked. The page covers single and multiple file selection, accepted file types, cancellation, JavaScript dialogs, Basic and Digest authentication, media, location, notifications, and each download state from issues 9 and 16.

Additional local pages:

- `/identity/lookalike` — Gmail title and a fake brand icon. The handle must still show `127.0.0.1`.
- `/inbox` — signed-in mail with an HttpOnly session cookie and a Sign out control, but no password field.
- `/public-article` — analytics cookies only.
- `/contact` — a business address in schema.org data, phone and email links, and sensitive values for Sharing Screen Mode: a valid and an invalid CPF, a test card, an API key, a labeled password, an IBAN, a password field, and an email added after load.
- `/runtime` — WebSocket echo, service worker registration, fullscreen, and history A/B.
- `/favicon/endless`, `/favicon/drip`, `/favicon/oversized` — favicon responses that never finish: a fast endless stream, one byte every 0.2 seconds, and a declared 10 MB body sent at 80 KB a second. `FaviconDownloadTests` starts the server on a free port with `python3 test-fixtures/server.py 0`.
- `/blocker/procedural`, `/blocker/redirect`, `/blocker/removeparam` — content blocker checks for `blocker-filters.txt`, the list the UI tests load in place of the standard lists (`INTERLINKED_UI_TEST_FILTERS`). Each page reports `pass` or the failed checks in its title. `/blocker/redirect` redirects from 127.0.0.1 to localhost, a different site, and the destination must get localhost's rules on its first document.
- `/tracking/redirect` — redirects to `/blocker/removeparam` with `utm_source` and `fbclid`. Interlinked removes tracking parameters from every page address and redirect even with blocking off, so the page must report only `keep=1`.

Failed login, upload, download, or popup on these local pages is a release blocker. The manual matrix for Gmail, Docs, GitHub, Slack, OAuth, a video meeting, and one checkout flow is `COMPATIBILITY.md`. Do not commit account passwords or payment details.

The popup section covers issue 12. GET and POST target-blank requests must open normal Interlinked tabs, report that `window.opener` is intact, and keep the POST body. The child Close button must close its tab. The user-initiated script popup must open; the delayed script popup must be blocked.

The navigation section covers issue 22. The misleading link and the cross-site redirect must both load `Navigation completed` without a warning.

The HTTP server binds only to loopback. Use `fixture` / `interlinked` for both authentication challenges. A client-certificate challenge needs a trusted TLS fixture configured to request a client identity; Interlinked cancels that unsupported flow and explains why in native UI.
