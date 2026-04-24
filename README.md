# Destila

Destila is an AI-powered workflow orchestration tool for software development. It manages multi-phase, AI-assisted workflows that take developers from rough ideas to implemented code.

## Run with Docker

An official container image is published to the GitHub Container Registry at
[`ghcr.io/esnunes/destila`](https://github.com/esnunes/destila/pkgs/container/destila).
It ships with Destila plus every required CLI pre-installed (`claude`, `tmux`,
`ffmpeg`, `agent-browser`, `git`) so you can run Destila without installing
Elixir, Erlang, Node, or the Claude Code CLI on your host.

### 1. Pull the image

```sh
docker pull ghcr.io/esnunes/destila:latest
```

Pin to a specific version (recommended for anything beyond a quick try) by
using a semver tag such as `ghcr.io/esnunes/destila:0.1.0`.

### 2. Generate a `SECRET_KEY_BASE`

Phoenix refuses to boot without a signing secret. Generate one once and reuse it:

```sh
export SECRET_KEY_BASE=$(openssl rand -hex 64)
```

### 3. Choose an authentication method

The three options below are mutually exclusive and resolved in the same
priority order as the [Authentication](#authentication) section. Pick one:

- **OAuth token (Claude subscription)** — pass via env var:

  ```sh
  -e CLAUDE_AGENT_OAUTH_TOKEN="sk-ant-oat01-..."
  ```

- **Anthropic API key** — pass via env var:

  ```sh
  -e ANTHROPIC_API_KEY="sk-ant-api03-..."
  ```

- **Pre-logged-in host** — mount your host `~/.claude` directory so the
  container reuses an existing `claude login` session:

  ```sh
  -v ~/.claude:/root/.claude
  ```

### 4. Run the container

```sh
mkdir -p ~/destila-data ~/.cache/destila

docker run -d \
  --name destila \
  -p 4000:4000 \
  -v ~/.claude:/root/.claude \
  -v ~/.cache/destila:/root/.cache/destila \
  -v ~/destila-data:/data \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e PHX_HOST=localhost \
  ghcr.io/esnunes/destila:latest
```

Open http://localhost:4000. Migrations run automatically on first boot; the
SQLite database lives at `/data/destila.db` (i.e. on the `~/destila-data`
mount).

### 5. Upgrade

```sh
docker pull ghcr.io/esnunes/destila:latest
docker rm -f destila
docker run -d --name destila ...   # same flags as step 4
```

Your projects, sessions, Claude login, and SQLite database all live on the
three mounted volumes and survive container recreation.

### Volumes

| Host path          | Container path          | Purpose                                                        |
| ------------------ | ----------------------- | -------------------------------------------------------------- |
| `~/.claude`        | `/root/.claude`         | Claude Code CLI credentials and settings.                      |
| `~/.cache/destila` | `/root/.cache/destila`  | Per-project git clones and workflow-session worktrees.         |
| `~/destila-data`   | `/data`                 | SQLite database (`destila.db` plus its WAL/SHM sidecar files). |

> The cache mount maps the host's `~/.cache/destila` — **not** `~/.cache`.
> Destila adds the `destila/` segment itself at `lib/destila/git.ex`; if you
> mount `~/.cache` you'll end up with clones at `~/.cache/destila/destila/...`.

### Limitations

- Services launched by Destila workflows bind to dynamic host ports inside
  the container and are therefore only reachable from the host if you run
  with `--network host` (Linux only) or forward the needed ports with
  additional `-p` flags at `docker run` time.
- The image is published for `linux/amd64` only. ARM hosts (Apple Silicon,
  Raspberry Pi, arm64 servers) need Docker's emulation layer or a custom
  local build.
- The container runs as `root` by default. Running with
  `--user $(id -u):$(id -g)` is possible but requires pre-creating the
  bind-mount directories (`~/.claude`, `~/.cache/destila`, `~/destila-data`)
  with matching ownership on the host — otherwise SQLite and the Claude CLI
  will hit `EACCES` on first write, since the image's `/data`, `/root/.claude`,
  and `/root/.cache/destila` paths are owned by `root` inside the image.

### Troubleshooting

- **`environment variable SECRET_KEY_BASE is missing`** — set
  `SECRET_KEY_BASE` on the `docker run` command line (see step 2).
- **Permission denied on volume mounts under SELinux / Podman** — append
  `:Z` to each bind mount, e.g. `-v ~/.claude:/root/.claude:Z`.
- **`Destila.Deps.check/0` reports `available?: false`** — rebuild the image
  from a clean checkout (`docker pull` for the official tag, or
  `docker build --no-cache` for a local build). The required CLIs are baked
  into the image and should never be missing at runtime.

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
