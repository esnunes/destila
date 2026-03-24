# What To Do When a Task Is Completed

1. **Run `mix precommit`** — this is the single command that validates everything:
   - `mix compile --warnings-as-errors` — ensures no compilation warnings
   - `mix deps.unlock --unused` — cleans up unused dependencies
   - `mix format` — formats all code
   - `mix test` — runs the full test suite

2. **Update Gherkin features** — if the change affects behavior described in `.feature` files:
   - Update corresponding scenarios to match new behavior
   - Add/update `@tag` annotations on tests
   - Remove `@tag` references to deleted scenarios

3. **Verify no security issues** — avoid command injection, XSS, SQL injection, etc.
