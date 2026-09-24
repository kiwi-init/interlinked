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

Failed login, upload, download, or popup on these local pages is a release blocker. The manual matrix for Gmail, Docs, GitHub, Slack, OAuth, a video meeting, and one checkout flow is `COMPATIBILITY.md`. Do not commit account passwords or payment details.

The popup section covers issue 12. GET and POST target-blank requests must open normal Interlinked tabs, report that `window.opener` is intact, and keep the POST body. The child Close button must close its tab. The user-initiated script popup may open after a navigation warning; the delayed script popup must be blocked.

The navigation section covers issue 22. The misleading link and cross-site redirect must show a warning before `Navigation completed` loads. Continuing can save an exact-origin, exact-warning exception, which can be revoked in Settings > Sites.

The HTTP server binds only to loopback. Use `fixture` / `interlinked` for both authentication challenges. A client-certificate challenge needs a trusted TLS fixture configured to request a client identity; Interlinked cancels that unsupported flow and explains why in native UI.
