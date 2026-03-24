# Code Style and Conventions

## Elixir
- Standard Elixir formatting via `mix format` with Phoenix plugin (`Phoenix.LiveView.HTMLFormatter`)
- Formatter imports deps from `:phoenix`
- No additional linting tools (no Credo configured)
- Predicate functions end with `?` (not `is_` prefix)
- Immutable variable rebinding — always bind block expression results

## Phoenix / LiveView
- Phoenix 1.8 patterns: `<Layouts.app>` wrapper, `to_form/2` for forms, streams for collections
- LiveViews named with `Live` suffix (e.g., `DashboardLive`, `CraftingBoardLive`)
- No LiveComponents unless strongly needed
- HEEx templates with `~H` sigil
- Colocated JS hooks (`:type={Phoenix.LiveView.ColocatedHook}`) with `.` prefix names
- `<.icon>` component for heroicons
- `<.input>` component for form inputs

## CSS / JS
- Tailwind CSS v4 (no config file, uses `@import "tailwindcss"` in app.css)
- No daisyUI — custom Tailwind components only
- No `@apply` in CSS
- All vendor deps imported via app.js/app.css (no external script/link tags)
- No inline `<script>` tags in templates

## BDD / Testing
- Gherkin feature files in `features/`
- Tests link to features via `@tag feature: "...", scenario: "..."`
- Use `start_supervised!/1` for process cleanup
- Use `Process.monitor/1` instead of `Process.sleep/1`
- Use `LazyHTML` for HTML assertions in tests

## Database
- SQLite via ecto_sqlite3
- Early-stage app — DB resets are acceptable over incremental migrations
