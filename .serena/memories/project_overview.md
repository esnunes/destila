# Destila - Project Overview

Destila is a web application built with the Phoenix framework (Elixir). It appears to be a prompt engineering / AI workflow tool with features for:

- **Projects management** — organizing work into projects
- **Prompt crafting** — a "Crafting Board" for building and refining prompts
- **AI integration** — AI query workers, sessions, and tool support (via `Destila.AI` module)
- **Workflow automation** — chore task workflows with phases
- **Message/chat system** — messages context with PubSub for real-time updates

## Tech Stack
- **Language**: Elixir ~> 1.15
- **Web framework**: Phoenix ~> 1.8.5 with LiveView ~> 1.1.0
- **Database**: SQLite via `ecto_sqlite3`
- **Background jobs**: Oban ~> 2.20 (with Oban Web UI)
- **CSS**: Tailwind CSS v4
- **JS bundler**: esbuild
- **Markdown**: Earmark for rendering, HtmlSanitizeEx for sanitization
- **HTTP client**: Req (via Phoenix default)
- **AI SDK**: claude_code ~> 0.32

## Codebase Structure
```
lib/destila/          — Business logic (contexts)
  ai/                 — AI integration (session, tools)
  messages/           — Message schema
  projects/           — Project schema
  prompts/            — Prompt schema
  workers/            — Oban workers (AI query, setup, title generation)
  workflows/          — Chore task phases
lib/destila_web/      — Web layer
  components/         — Core, chat, board, layout components
  controllers/        — Session controller, error handlers
  live/               — LiveViews (dashboard, crafting board, prompts, projects, session)
  plugs/              — Auth plug
config/               — Environment configs
features/             — BDD Gherkin feature files
test/                 — Tests (mirrors lib structure)
assets/               — JS and CSS assets
priv/                 — Migrations, static assets
```
