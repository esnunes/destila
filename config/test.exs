import Config

# Configure your database for tests
config :destila, Destila.Repo,
  database: Path.expand("../destila_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 16

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :destila, DestilaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IkcMKJiYHymo++4aGJ/B+1cyjIx0Oh3jPxBUePu/sw3MkTFVgd8n3FKIHgqjviR2",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use test adapter for ClaudeCode
config :claude_code, adapter: {ClaudeCode.Test, ClaudeCode}

# Execute Oban jobs inline during tests for synchronous behavior
config :destila, Oban, testing: :inline

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
