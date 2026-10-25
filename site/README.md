# interlinked.kiwiinit.com

Interlinked's page: what it is, what it does, and how to get it. It is static files in `public/`, served by a Cloudflare Worker that does nothing but serve them, at interlinked.kiwiinit.com. It is built like [kiwiinit.com](https://github.com/kiwi-init/kiwiinit.com), in the style of Channels' site: OLED black, Paper Mono for headings and labels, SF Pro for body text, the same colour tokens, copy boxes and spectrum sheen.

## Files

- `public/index.html`, `public/styles.css`, `public/app.js`: the page, hand-written, no build step. `app.js` only runs the copy buttons. It is a file of its own so the CSP can stay `script-src 'self'`.
- `public/hero.js`: the hero's two linked glass frames, the icon's mark in 3D, raymarched in WebGL in the manner of Channels' `site/world.js`. They drift in, link as they do in the icon while a band of spectral light crosses them, and settle; after that it draws only to lean them towards the pointer, and nothing while the hero is off-screen or the tab is hidden. With reduced motion they're drawn once, linked. Without WebGL (or without JavaScript) the icon's SVG stays in their place.
- `public/404.html`: what any other path shows.
- `public/_headers`: the security headers, the same CSP as Channels' site and kiwiinit.com.
- `public/icon.svg`: the app icon, from `script/app-icon/icon.svg` with its viewBox cropped to the icon's square, as on kiwiinit.com.
- `public/media/*.jpg`: the app at 1520×950, taken from an isolated copy (`script/run-isolated`), never anyone's own data. The contacts in `sharing.jpg` are made up (example.com addresses, 555 numbers, a test card number).
- `public/fonts/`: Paper Mono (`PaperMono.woff2`, SIL OFL 1.1 in `PaperMono-OFL.txt`).
- `wrangler.jsonc`: the Worker: static assets from `public/`, `404-page` for unknown paths, and interlinked.kiwiinit.com as its custom domain.

The Download buttons open the latest release on [kiwi-init/interlinked-releases](https://github.com/kiwi-init/interlinked-releases/releases/latest), so a new release needs no change here.

## Look at it locally

From this folder:

```sh
npx wrangler@4 dev
```

That serves it at http://localhost:8787 with the headers applied. Without Node, `python3 -m http.server -d public 8787` shows the same page without the headers.

## Put it on interlinked.kiwiinit.com

This needs the Cloudflare account that owns kiwiinit.com, so it is a person's job, done once:

1. Log wrangler in to that account. It opens the browser:

   ```sh
   npx wrangler@4 login
   ```

2. If `interlinked.kiwiinit.com` already has a DNS record, delete it. A Worker's custom domain needs the name free, and the deploy creates its own record.

3. From this folder, deploy:

   ```sh
   npx wrangler@4 deploy
   ```

   It uploads `public/` and attaches interlinked.kiwiinit.com to the Worker.

4. Open https://interlinked.kiwiinit.com.

After that, every change ships with `npx wrangler@4 deploy` again, from this folder.
