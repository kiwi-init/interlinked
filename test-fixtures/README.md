# Browser capability fixtures

Run:

```sh
python3 test-fixtures/server.py
```

Open `http://127.0.0.1:8765` in Interlinked. The page covers single and multiple file selection, accepted file types, cancellation, JavaScript dialogs, Basic and Digest authentication, media, location, notifications, and each download state from issues 9 and 16.

The HTTP server binds only to loopback. Use `fixture` / `interlinked` for both authentication challenges. A client-certificate challenge needs a trusted TLS fixture configured to request a client identity; Interlinked cancels that unsupported flow and explains why in native UI.
