# Suggested Commands

## Development
- **Start server**: `elixir --sname destila -S mix phx.server`
- **Remote shell (debugging)**: `iex --sname debug --remsh destila@$(hostname -s)`
- **One-off RPC**: `elixir --sname tmp -e 'Node.connect(:"destila@<hostname>"); :rpc.call(:"destila@<hostname>", Module, :function, [args])'`
- **Interactive console**: `iex -S mix`

## Setup
- **Full setup**: `mix setup` (deps, DB, assets, git hooks)
- **DB reset**: `mix ecto.reset` (drop + create + migrate)
- **DB migrate**: `mix ecto.migrate`

## Testing
- **Run all tests**: `mix test`
- **Run single file**: `mix test test/path/to/test.exs`
- **Run failed tests**: `mix test --failed`
- **Run by feature tag**: `mix test --only feature:feature_name`
- **Run by scenario tag**: `mix test --only "scenario:Scenario name"`

## Code Quality
- **Pre-commit (run when done)**: `mix precommit` — runs compile (warnings-as-errors), unlock unused deps, format, test
- **Format code**: `mix format`
- **Compile with warnings**: `mix compile --warnings-as-errors`

## Assets
- **Build assets**: `mix assets.build`
- **Deploy assets**: `mix assets.deploy`

## System Utilities (Darwin/macOS)
- `git`, `grep`, `find`, `ls`, `cd` — standard unix commands available
