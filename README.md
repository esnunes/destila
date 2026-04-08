# Destila

Destila is an AI-powered workflow orchestration tool for software development. It manages multi-phase, AI-assisted workflows that take developers from rough ideas to implemented code.

## Getting started

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Run `mix destila.setup` to verify the Claude CLI is available (see [Claude CLI](#claude-cli))
* Set the required environment variables (see below)
* Start Phoenix endpoint with `elixir --sname destila -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Claude CLI

Destila shells out to the `claude` CLI to drive AI sessions. It resolves the
binary from your system (`$PATH` and common install locations like
`~/.local/bin/claude`) via `config :claude_code, cli_path: :global`, so you
must have Claude Code installed before starting the server.

Check availability with:

```sh
mix destila.setup
```

If the CLI is missing, install it with the official script:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

This places the binary at `~/.local/bin/claude`. Make sure `~/.local/bin` is
on your `$PATH`, then re-run `mix destila.setup`. Other install methods are
documented at https://docs.anthropic.com/en/docs/claude-code.

### Remote shell

The server starts as a named Erlang node (`destila@<hostname>`), which allows connecting a remote shell for debugging and live data inspection:

```sh
iex --sname debug --remsh destila@$(hostname -s)
```

From the remote shell you can inspect and modify ETS data, call application functions, etc.

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
