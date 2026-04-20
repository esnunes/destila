# docs/ — production landing page

This folder is the build output served to `destila.nunes.dev` by GitHub
Pages. The HTML and static assets (images, `CNAME`) live here in source
control; `assets/app.js` is **build output** and is not tracked — it's
produced by `mix landing.build` (and automatically by CI on every
push to `main`).

## Files

- `index.html` — stripped production HTML (no Tweaks panel, production React)
- `assets/app.js` — **generated**, gitignored; produced from `../src/*.jsx`
- `assets/*.png` — product screenshots (served separately so the browser can cache them)
- `CNAME` — custom domain for the Pages site

## How deploys work

GitHub Pages is configured with **Source: GitHub Actions**. The workflow
at `.github/workflows/deploy-landing.yml` runs on every push to `main`
that touches `landing/**` (or the build config), and does three things:

1. `mix deps.get`
2. `mix landing.build` — concatenates `landing/src/*.jsx` and transpiles
   with esbuild into `landing/docs/assets/app.js`
3. `actions/upload-pages-artifact` + `actions/deploy-pages` ship the
   contents of `landing/docs/` to the Pages site

No `gh-pages` branch. No manual copy step. Edits to either the JSX
sources or the HTML go live on the next push to `main`.

## Building locally

From the repo root:

```sh
mix landing.build
```

This invokes the `Mix.Tasks.Landing.Build` task (in
`lib/mix/tasks/landing.build.ex`), which uses the project's `:esbuild`
dependency under the `:landing` profile configured in
`config/config.exs`. No separate Node/npm install is needed — the
esbuild Elixir wrapper downloads and runs the native binary.

To preview, open `landing/docs/index.html` directly or serve the
directory with any static server:

```sh
python3 -m http.server --directory landing/docs 8000
```

## Editing

- **HTML / meta / analytics / CSS**: edit `landing/docs/index.html`
  directly. It's committed as-is.
- **React UI**: edit `landing/src/*.jsx`. The task concatenates them in
  this fixed order (defined in the task module):
  1. `mocks.jsx` — shared component primitives
  2. `shot.jsx` — screenshot helpers
  3. `variation-minimal.jsx` — the production variation
  4. `app.jsx` — React root and variation picker
  Each file may declare its own `const { useState, ... } = React;`; the
  task strips those per-file declarations and emits a single superset at
  the top of the combined bundle.
- After JSX edits, bump the `?v=` query param on the `<script src="assets/app.js?v=…">`
  tag in `index.html` to bust browser caches.

## Why this shape

- **Single source of truth.** `landing/src/` is the source; `landing/docs/`
  is the deploy root. No drift between branches.
- **Same toolchain as the rest of the app.** `:esbuild` is already a
  project dependency — no extra Node/Vite/webpack footprint.
- **Production React** (`react.production.min.js`) — ~45 KB vs ~1 MB dev
  build. Loaded via CDN, not bundled.
- **Separate image files** so browsers cache them across visits.
- **`<img loading="lazy">`** on every non-hero screenshot — only the hero
  loads eagerly.
- **Preload hint** on the hero image so LCP is snappy.
- **Open Graph + Twitter meta** so link previews on GitHub/Twitter/Slack
  render nicely.
