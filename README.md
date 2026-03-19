# Destila

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Set the required environment variables (see below)
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Authentication

Authentication with the Anthropic API is required for AI-powered features such as automatic prompt title generation. The SDK checks credentials in the following order:

1. **`CLAUDE_AGENT_OAUTH_TOKEN`** — OAuth token (highest priority)
2. **`ANTHROPIC_API_KEY`** — API key
3. **CLI login** — existing `claude login` session

You only need one of these methods.

### Using a Claude Code subscription (Max or Team plan)

Run the setup command to generate and store an OAuth token tied to your subscription:

```sh
claude setup-token
```

This sets `CLAUDE_AGENT_OAUTH_TOKEN` for you. Alternatively, export it manually:

```sh
export CLAUDE_AGENT_OAUTH_TOKEN="sk-ant-oat01-..."
```

### Using an Anthropic API key (pay-as-you-go)

1. Go to https://console.anthropic.com/settings/keys
2. Click "Create Key", name it (e.g. "destila-dev"), and copy the key
3. Export it:

```sh
export ANTHROPIC_API_KEY="sk-ant-api03-..."
```

### Using CLI login (local development)

If you already have Claude Code installed and logged in:

```sh
claude login
```

The SDK will use the existing session automatically.

Add your chosen env var to your shell profile (`~/.zshrc`, `~/.bashrc`) for persistence.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
