# docs/ — production landing page

This folder contains the deployable landing page. Copy it to
`esnunes/destila` and enable GitHub Pages.

## Files

- `index.html` — stripped production HTML (no Tweaks panel, production React)
- `assets/app.js` — pre-compiled JSX bundle (no in-browser Babel)
- `assets/*.png` — product screenshots (served separately so the browser can cache them)

## Deploy to GitHub Pages

1. Copy this `docs/` folder to the root of the `esnunes/destila` repo.
2. Commit and push to `main`.
3. Repo **Settings → Pages**:
   - Source: **Deploy from a branch**
   - Branch: **main** · Folder: **/docs**
4. Wait ~1 min. Site goes live at `https://esnunes.github.io/destila/`.

## Custom domain (optional)

1. Create `docs/CNAME` with your domain on a single line (e.g. `destila.dev`).
2. At your DNS provider add:
   - Apex → 4 A records to GitHub Pages IPs (185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153), OR
   - Subdomain → CNAME → `esnunes.github.io`.
3. Settings → Pages → Custom domain → enter the domain → Enforce HTTPS.

## Rebuilding after edits

The JSX lives in `../src/*.jsx` in the design project. To rebuild:

1. Edit the source files (`src/mocks.jsx`, `src/variation-minimal.jsx`, etc.).
2. Run the bundler (Babel standalone) — it concatenates + transpiles them into
   `docs/assets/app.js`. The process removes the duplicate
   `const { useState, useEffect } = React;` that each source file declares.
3. Bump the `?v=` query param on the `<script src="assets/app.js?v=…">` tag in
   `index.html` to bust caches.

## Why this shape

- **Separate image files** so browsers cache them across visits.
- **Production React** (`react.production.min.js`) — ~45 KB vs ~1 MB dev build.
- **No runtime Babel** — the whole page is ready as soon as `app.js` parses.
- **`<img loading="lazy">`** on every non-hero screenshot — only the hero loads eagerly.
- **Preload hint** on the hero image so LCP is snappy.
- **Open Graph + Twitter meta** so link previews on GitHub/Twitter/Slack render nicely.
