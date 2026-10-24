# Interlinked Jev relay

The relay keeps the OpenRouter key out of the macOS app. TestFlight supplies an App Store-signed `AppTransaction`; the relay verifies that signature and the `computer.interlinked` bundle ID before it accepts a Jev request.

It stores only a SHA-256 request hash and the Jev response in a local SQLite database for five days. It does not store the page URL, page text, query, signed App Transaction, or OpenRouter key. Identical meaning searches can therefore share a result across testers without a URL-based tracking database.

Required deployment configuration:

- `OPENROUTER_API_KEY` as a runtime secret
- a persistent volume mounted at `/data`
- unauthenticated HTTPS access to `POST /v1/jev`; the signed App Transaction is the request authentication

Build and test locally with `npm ci && npm test`. Run the container behind HTTPS with its port bound only to loopback, then archive Interlinked with `INTERLINKED_JEV_RELAY_URL=https://<host>/v1/jev`. Set `INTERLINKED_RELAY_DB` only when the database should live somewhere other than `/data/interlinked-relay.sqlite`. Do not put the OpenRouter key in an Xcode build setting, plist, source file, or GitHub Actions variable that gets copied into the app.

The current private-TestFlight relay runs on the existing `sp-devbox` VPS. Its origin listens only on `127.0.0.1:8787`; Caddy provides HTTPS at `https://interlinked-jev.187-77-224-188.sslip.io`. Docker restart policies keep both containers running after a reboot. The firewall exposes only ports 80 and 443 for certificate renewal and HTTPS traffic.
