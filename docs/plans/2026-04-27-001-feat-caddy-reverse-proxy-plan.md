---
title: "feat: Caddy reverse proxy for development services"
type: feat
status: active
date: 2026-04-27
---

# feat: Caddy reverse proxy for development services

## Overview

Destila currently advertises every running development service as
`http://localhost:<port>`. This plan adds an opt-in reverse-proxy path
that routes traffic to those local processes through a user-managed
Caddy instance via Caddy's admin HTTP API:

- **Project services** can declare an optional fully-qualified `domain`
  and an optional `basic_auth_enabled` toggle. When `domain` is set,
  Destila registers a route on start and unregisters on stop.
- **Session services** are *always* registered as
  `<session_id>.<DESTILA_BASE_DOMAIN>` and *always* protected by basic
  auth.
- A new `Destila.Proxy.Caddy` module wraps Caddy's admin API with `Req`.
- A single `Destila.Services.Url` helper computes the advertised URL,
  used by the services index, the service detail page, and the
  workflow-runner sidebar globe button. Localhost fallbacks remain
  intact when no route is registered.

The change is invisible to existing users with no Caddy and no domain
configured: nothing about the local process lifecycle changes, and the
advertised URL stays `http://localhost:<port>`.

## Problem Frame

Destila users running multiple sessions on the same machine — and users
who want to share a preview of a project service — currently can't get
a stable URL or any kind of access control. Localhost ports are
ephemeral, conflict-prone, and not shareable. Users already commonly
run a Caddy instance for personal projects; we want Destila to plug
into that Caddy rather than manage a proxy ourselves.

## Requirements Trace

- **R1.** Each project schema gains optional `domain` (RFC-1123
  hostname, non-unique) and `basic_auth_enabled` (boolean, default
  false) fields, exposed in create + edit forms.
- **R2.** Project services with a non-blank `domain` register a Caddy
  route at `<project.domain>` on start and unregister on stop.
- **R3.** Session services always register a Caddy route at
  `<session_id>.<DESTILA_BASE_DOMAIN>` on start, always behind basic
  auth, and unregister on stop.
- **R4.** Routes carry deterministic IDs:
  `destila-project-<project_id>` and `destila-session-<session_id>`.
- **R5.** Restart performs delete-then-add against the same `@id`
  (brief no-route window acceptable).
- **R6.** When basic auth is required for a service and either credential
  env var is missing, the start is blocked *before* the local process
  is spawned, with a clear error.
- **R7.** When the Caddy admin URL is unreachable (TCP failure on the
  pre-call probe), register/unregister is a silent no-op; the local
  service still starts/stops and the UI advertises the localhost URL.
- **R8.** When the probe succeeds but the API returns non-2xx, the
  failure is logged and surfaced as an error flash on the relevant
  detail page; no auto-retry.
- **R9.** A single helper computes the advertised URL from a
  project/session and its registration state, used by the services
  index, service detail page, and workflow-runner sidebar globe button.
- **R10.** Configuration is env-vars-only:
  `DESTILA_BASE_DOMAIN` (default `localhost`),
  `DESTILA_CADDY_ADMIN_URL` (default `http://localhost:2019`),
  `DESTILA_BASIC_AUTH_USER`, `DESTILA_BASIC_AUTH_PASSWORD` (no
  defaults).
- **R11.** No boot-time reconciliation: routes are touched only on
  subsequent start/stop/restart events, not on Destila boot.
- **R12.** A new `features/caddy_proxy.feature` captures the
  cross-cutting reverse-proxy behavior; existing service feature files
  are tightened to make "no configured domain" an explicit
  precondition for localhost-URL scenarios and to add domain/session
  URL scenarios.

## Scope Boundaries

- **Out of scope:**
  - Settings UI for any new env var.
  - Reconciling pre-existing Caddy routes at boot.
  - Per-session or per-project basic-auth credential overrides.
  - Managing Caddy's TLS certificates, ACME settings, or upstream Caddy
    configuration beyond inserting/removing route objects.
  - Real-Caddy or browser-level E2E coverage.
- **In scope but explicitly minimal:**
  - The Caddy server name to POST routes into is fixed at `srv0` (the
    name Caddy gives the default server when `caddy run` loads a config
    via `caddy adapt`). Documented as an assumption; see Open Questions.

## Context & Research

### Relevant Code and Patterns

- **Service lifecycle hook:** `lib/destila/services/service_manager.ex`
  — `do_start/1` (after `wait_for_port` returns true, line ~191) is
  the register site; `do_stop/1` (line ~210) and `cleanup_target/1`
  (line 128) are unregister sites. Every external caller funnels here.
- **Target abstraction:**
  `lib/destila/services/target.ex` — the `%Target{}` already carries
  `kind` (`:session | :project`), `id`, `project`, `workflow_session`.
  Enough to compute the deterministic Caddy `@id` and host without
  modifying call sites.
- **Project schema:** `lib/destila/projects/project.ex` — pattern of
  `add_error/3`-based field validators (`validate_git_repo_url/1`,
  `validate_service_env_var/1`) is the template for the hostname
  validator. `mise_auto_trust` (boolean, default false) is the
  template for `basic_auth_enabled`.
- **Project form:** `lib/destila_web/live/project_form_live.ex` —
  `assign_new(:form, ...)` map (lines 18–27), `non_blank/to_bool`
  flow in `handle_event("save", ...)` (lines 36–64), and
  `changeset_to_errors/1` (lines 75–82) are the four touchpoints for
  adding a field.
- **HTTP client:** `lib/destila/ai/auth_login.ex:339` — established
  pattern is `Application.get_env(:destila, :<thing>_http_client, Req)`
  for test injection. We will adopt `Req.Test` plug stubbing for the
  new module, which is more idiomatic for `Req` and preserves the same
  injection seam.
- **Test conventions:** `test/destila/services/project_services_test.exs`
  — Mimic + `set_mimic_from_context`; `@feature` constant + `@tag
  feature: @feature, scenario: "..."` per test (`AGENTS.md` lines
  112–120). `test/test_helper.exs` is where new stubbable modules are
  declared via `Mimic.copy/1`.
- **URL helper sites to consolidate:**
  - `lib/destila_web/live/services_live.ex:300-306` (`running_url/1`)
    and inline labels at lines 211, 274.
  - `lib/destila_web/live/service_detail_live.ex:643-667` (`url_link/1`).
  - `lib/destila_web/live/workflow_runner_live.ex:1568-1571`
    (`service_url/2`) and globe button at lines 1133–1144.
- **Migrations:** `priv/repo/migrations/` flat directory; recent
  precedent at `priv/repo/migrations/20260424120000_add_service_state_to_projects.exs`.
  Convention: `def change`, plain `add :col, :type`, booleans take
  `null: false, default: false`.
- **Configuration:** `config/runtime.exs` is the only place env vars
  are read at boot. No `Destila.Config` module exists; we will follow
  the inline `System.get_env/2` pattern and surface a small
  `Destila.Proxy.Config` module only if needed for the `Req.Test`
  injection seam.

### Institutional Learnings

- `docs/solutions/` contains nothing relevant to Caddy, reverse
  proxies, hostname validation, `Req.Test`, probe-then-call, or
  basic-auth hashing. This is greenfield in the codebase. The closest
  prior plan is `docs/plans/2026-04-24-003-feat-project-level-services-plan.md`,
  which establishes the lifecycle this plan hooks into.
- The Gherkin tagging convention is documented in
  `AGENTS.md`/`CLAUDE.md` and re-stated in
  `docs/plans/2026-04-15-003-feat-gherkin-phase-structured-tools-plan.md`:
  every scenario must have at least one linked test via
  `@tag feature: ..., scenario: ...`.

### External References

- Caddy admin API:
  - `POST /config/apps/http/servers/<srv>/routes` appends a route to
    the routes array. Success: 200.
  - `DELETE /id/<id>` removes the object indexed by `@id`. Success:
    200; missing id: 404 (treat as success).
  - Re-adding the same `@id` after delete works; adding a duplicate
    `@id` while another exists is rejected during config load (4xx).
    Therefore restart must do **delete-first** unconditionally.
  - `GET /config/` is the canonical reachability probe.
  - Source: <https://caddyserver.com/docs/api>,
    <https://caddyserver.com/docs/api-tutorial>.
- Caddy `basic_auth` handler: handler module name is `authentication`
  with provider `http_basic`; `password` accepts a Modular Crypt
  Format string starting with `$` directly (e.g. `$2b$...` from
  `bcrypt_elixir`). No base64 wrapping required.
  Source: <https://caddyserver.com/docs/caddyfile/directives/basic_auth>
  and `caddyserver/caddy/modules/caddyhttp/caddyauth/basicauth.go`.
- Automatic HTTPS: hosts in `match.host` automatically trigger
  Caddy's auto-HTTPS. `*.localhost` does technically receive a local
  self-signed cert from Caddy's local CA, but the *advertised* scheme
  is what Destila controls. Per the spec: `http://` for any host
  ending in `.localhost`, `https://` for everything else.
  Source: <https://caddyserver.com/docs/automatic-https>.

## Key Technical Decisions

- **Hook at `ServiceManager.do_start`/`do_stop`/`cleanup_target`** —
  every project and session start/stop funnels here (verified across
  ~9 call sites). Project and session context modules stay unaware of
  the proxy. Rationale: a single insertion seam keeps the proxy
  invisible to LiveViews and the AI tools layer.
- **Probe-then-call with silent no-op on TCP failure** — matches the
  spec's "no error surfaced" requirement and keeps Destila usable on
  machines with no Caddy. Probe is `GET /config/` with a short timeout.
- **Deterministic `@id` per target** — `destila-project-<uuid>` and
  `destila-session-<uuid>`. Lets restart be a clean
  delete-then-add-by-id without bookkeeping.
- **Restart = unconditional DELETE then POST** — handles the case of
  a previous crash that left a stale route in Caddy. DELETE 404 is
  treated as success.
- **Password hashed once via `bcrypt_elixir`, cached in `:persistent_term`** —
  the `basic_auth` handler accepts the raw `$2b$...` MCF string;
  hashing on every register is wasteful, hashing on first use is
  enough since the credential never changes within a BEAM run.
- **`Req.Test` plug stubbing for tests** — the codebase has zero
  `Req.Test` precedent. We will introduce it as the canonical pattern
  for new external HTTP integrations. Application-env injection seam
  is preserved (`Application.get_env(:destila, :caddy_req_options,
  [])`) so tests can pass `plug: {Req.Test, Destila.Proxy.Caddy}`.
- **Persist a `caddy_route` boolean into `service_state`** — the URL
  helper needs to know whether a route was actually registered. We
  store `service_state["caddy_route"]` = `true | false` on every
  start; URL helper falls back to localhost when false or absent. No
  schema change beyond what's already a JSON map.
- **Server name fixed at `srv0`** — Caddy's default. Surface as a
  documented assumption rather than a fifth env var, per the spec's
  "env vars only" enumeration.
- **URL scheme rule lives in the new helper, not in Caddy** —
  `http://` for any host ending in `.localhost`; `https://` for
  everything else. The advertised URL is what the user clicks; Caddy
  serves whatever it's configured to serve. Mismatches (e.g. user
  has Caddy serving HTTPS on `*.localhost`) are user-config concerns.
- **Missing-creds preflight only when basic auth is required** — for
  sessions: always; for projects: only when `basic_auth_enabled` is
  true. A project service without basic auth can start without
  credentials configured, even if Caddy is reachable.

## Open Questions

### Resolved During Planning

- **Caddy server name to target?** → Fixed at `srv0` for v1. The spec
  enumerates exactly four env vars; we honor that. The README addition
  in Unit 8 will document this assumption.
- **Where does the `caddy_route` flag live?** → In the existing
  `service_state` JSON map, alongside `port`/`status`/etc. No
  migration impact.
- **Probe timeout?** → 500ms (matches the existing
  `@port_probe_timeout_ms` in `ServiceManager`). Short enough to keep
  start latency unaffected when Caddy is down.
- **What happens to project services without a domain when
  `basic_auth_enabled` is true?** → No-op. `basic_auth_enabled`
  without a `domain` produces no Caddy route, so the basic-auth toggle
  is irrelevant in that case; the preflight credential check still
  fires only when a route would be registered. Documented in scenario
  prose.
- **`Req.Test` vs the existing `auth_login_http_client` Mimic-style
  pattern?** → `Req.Test` plug stubbing. Cleaner for the JSON request
  bodies the Caddy admin API takes, and a forward-leaning convention
  for future external integrations.

### Deferred to Implementation

- **Exact bcrypt cost factor.** Default to whatever `bcrypt_elixir`'s
  `Bcrypt.hash_pwd_salt/1` uses (currently 12). Confirm it's tolerable
  on first-call latency.
- **Whether to expose `service_state["caddy_route"]` to the
  detail-page UI as a small badge.** Probably yes for diagnostic
  value, but not required by the spec; settle once the helper lands.
- **Final shape of the LiveView error flash for non-2xx Caddy
  responses.** Per spec, surface on the relevant detail page; the
  exact wording / where on the page is a UI nuance to settle in
  implementation.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance
> for review, not implementation specification. The implementing agent
> should treat it as context, not code to reproduce.*

### Component map

```mermaid
flowchart TB
    LV[LiveViews\nservices_live, service_detail_live,\nworkflow_runner_live] -->|reads| URL[Destila.Services.Url\n(advertised URL helper)]

    PS[Destila.Services.ProjectServices] --> SM
    WF[Destila.Workflows / SessionProcess] --> SM
    AIT[Destila.AI.Tools] --> SM

    SM[Destila.Services.ServiceManager\n(do_start / do_stop /\ncleanup_target)]
    SM -->|on start success| Caddy[Destila.Proxy.Caddy]
    SM -->|on stop / cleanup| Caddy
    SM -->|persists service_state\n+ caddy_route flag| State[(projects.service_state\nworkflow_sessions.service_state)]

    Caddy -->|probe + register/unregister| Admin[(Caddy admin API\nDESTILA_CADDY_ADMIN_URL)]
    Caddy -->|reads creds| Cfg[(env: DESTILA_BASIC_AUTH_USER,\nDESTILA_BASIC_AUTH_PASSWORD,\nDESTILA_BASE_DOMAIN)]

    URL -->|reads| State
    URL -->|reads project.domain\n+ basic_auth_enabled| Proj[(projects.domain,\nprojects.basic_auth_enabled)]
```

### Caddy register/unregister flow

```mermaid
sequenceDiagram
    participant SM as ServiceManager.do_start
    participant Caddy as Destila.Proxy.Caddy
    participant API as Caddy admin API

    SM->>SM: wait_for_port returns true
    SM->>Caddy: register(target, port)
    Caddy->>Caddy: compute host, route_id, scheme
    Caddy->>Caddy: preflight: required basic auth + creds present?
    alt creds missing & required
        Caddy-->>SM: {:error, :missing_credentials}
        SM->>SM: do_stop(target); return error
    else creds OK or not required
        Caddy->>API: GET /config/ (probe, 500ms)
        alt probe fails (TCP)
            Caddy-->>SM: {:ok, :no_proxy}
            SM->>SM: persist caddy_route=false; running
        else probe succeeds
            Caddy->>API: DELETE /id/<route_id>
            Note over Caddy,API: 200 or 404 both treated as success
            Caddy->>API: POST /config/apps/http/servers/srv0/routes\n{@id, match.host, handle:[auth?, reverse_proxy]}
            alt 2xx
                Caddy-->>SM: {:ok, :registered}
                SM->>SM: persist caddy_route=true; running
            else non-2xx
                Caddy-->>SM: {:error, {:caddy_status, code, body}}
                SM->>SM: persist caddy_route=false; running;\nbroadcast error flash
            end
        end
    end
```

### URL helper resolution

```mermaid
flowchart TB
    Start[Url.for(target_or_record,\nservice_state)] --> Running{status == running\n& port present?}
    Running -- no --> NilURL[returns nil]
    Running -- yes --> RouteOK{caddy_route == true?}
    RouteOK -- no --> Localhost["http://localhost:&lt;port&gt;"]
    RouteOK -- yes --> Kind{kind?}
    Kind -- session --> SessHost["&lt;session_id&gt;.&lt;BASE_DOMAIN&gt;"]
    Kind -- project --> ProjHost{project.domain blank?}
    ProjHost -- yes --> Localhost
    ProjHost -- no --> ProjHostName["project.domain"]
    SessHost --> Scheme[scheme: ends_with .localhost? \nhttp : https]
    ProjHostName --> Scheme
    Scheme --> URL[scheme + :// + host]
```

## Implementation Units

- [ ] **Unit 1: Project schema fields and hostname validator**

**Goal:** Add `domain` (string, optional, RFC-1123 hostname) and
`basic_auth_enabled` (boolean, default false) to the `projects` table,
the `Destila.Projects.Project` schema, and its changeset. Strict
validation matching the spec edge cases.

**Requirements:** R1, R12.

**Dependencies:** None.

**Files:**
- Create: `priv/repo/migrations/20260427HHMMSS_add_domain_and_basic_auth_to_projects.exs`
- Modify: `lib/destila/projects/project.ex`
- Test: `test/destila/projects/project_test.exs` (create file if absent)

**Approach:**
- Migration follows the
  `20260424120000_add_service_state_to_projects.exs` convention:
  `add :domain, :string` and
  `add :basic_auth_enabled, :boolean, null: false, default: false`.
- Schema: `field :domain, :string` and
  `field :basic_auth_enabled, :boolean, default: false`. Add both to
  `cast/3` field list.
- New `validate_domain/1` private function patterned after
  `validate_git_repo_url/1` and `validate_service_env_var/1`. Applied
  via the changeset pipeline.
- Hostname validator rules:
  - blank → no error (field is optional)
  - trim trailing dots before validation
  - reject empty labels (consecutive dots, leading/trailing dot after
    trim)
  - reject labels longer than 63 chars
  - reject total length over 253 chars
  - allow only `[A-Za-z0-9-]` per label, no leading/trailing hyphen
    in any label
  - reject single-label hostnames? **No.** Spec says "fully-qualified
    domain name" but also explicitly allows `localhost`-only base
    domain. We allow single-label hosts. The user is responsible for
    Caddy resolving them.
- No uniqueness constraint per spec.

**Patterns to follow:**
- `lib/destila/projects/project.ex` `validate_service_env_var/1` for
  the `add_error` shape.
- `priv/repo/migrations/20260422180425_add_mise_auto_trust_to_projects.exs`
  for the boolean column pattern.

**Test scenarios:**
- Happy path: `valid?` is true when `domain` is `"app.example.com"`
  and `basic_auth_enabled` is `false`.
- Happy path: `valid?` is true when `domain` is blank.
- Happy path: trailing dot is trimmed before validation
  (`"app.example.com."` is accepted as `"app.example.com"`); the
  trimmed value is what gets persisted.
- Edge case: `"localhost"` (single label) is accepted.
- Edge case: domain exactly 253 chars total → accepted; 254 chars →
  rejected.
- Edge case: label exactly 63 chars → accepted; 64 chars → rejected.
- Error path: empty label (`"app..example.com"`) → rejected.
- Error path: leading/trailing hyphen in a label
  (`"-app.example.com"`, `"app-.example.com"`) → rejected.
- Error path: disallowed character (`"app_x.example.com"`,
  `"app x.example.com"`) → rejected.
- Error path: unique constraint is *not* added — two changesets with
  the same domain both validate cleanly.
- Happy path: `basic_auth_enabled: true` is accepted regardless of
  domain.

**Verification:**
- `mix test test/destila/projects/project_test.exs` passes.
- `Project.changeset(%Project{}, %{name: "x", local_folder: "/", domain: "app.example.com"})` is valid.
- Existing `Project.webservice?/1` behavior is unchanged.

---

- [ ] **Unit 2: Configuration surface for env vars**

**Goal:** Read the four env vars at runtime and expose them via a
single accessor. Provide a test seam for the Caddy admin URL.

**Requirements:** R10.

**Dependencies:** None.

**Files:**
- Create: `lib/destila/proxy/config.ex`
- Modify: `config/runtime.exs`
- Test: `test/destila/proxy/config_test.exs`

**Approach:**
- `Destila.Proxy.Config` exposes `base_domain/0`, `admin_url/0`,
  `basic_auth_user/0`, `basic_auth_password/0`. Each reads from
  `Application.get_env(:destila, :proxy, [])` with the spec defaults
  applied at the function level (so tests can override individual
  keys without restating defaults).
- `config/runtime.exs` populates the keyword list from `System.get_env/2`
  with the documented defaults: `base_domain` → `"localhost"`,
  `admin_url` → `"http://localhost:2019"`. User/password have no
  defaults — `nil` when unset.
- Also expose `req_options/0` returning `[]` by default. Like the
  other accessors, it reads from the same `:proxy` keyword list:
  `Application.get_env(:destila, :proxy, []) |> Keyword.get(:req_options, [])`.
  Tests override via `Application.put_env(:destila, :proxy,
  Keyword.put(existing, :req_options, plug: {Req.Test,
  Destila.Proxy.Caddy}))`.
- No changes for `:test` config: tests inject via
  `Application.put_env/3` per-test, mirroring the
  `auth_login_http_client` pattern.

**Patterns to follow:**
- `config/runtime.exs:33-34` for the `String.to_integer / get_env`
  pattern.
- `lib/destila/ai/auth_login.ex:339` for the
  `Application.get_env/3`-with-default helper pattern.

**Test scenarios:**
- Happy path: with no `Application.put_env/3` override and no env
  vars, `base_domain/0` returns `"localhost"` and `admin_url/0`
  returns `"http://localhost:2019"`.
- Happy path: when `:proxy` keyword list is overridden in
  `Application.put_env/3`, accessors return the overrides.
- Happy path: `basic_auth_user/0` and `basic_auth_password/0` return
  `nil` when unset.
- Edge case: `req_options/0` returns `[]` by default and the
  overridden value when set.

**Verification:**
- `mix test test/destila/proxy/config_test.exs` passes.
- `iex` smoke check: `Destila.Proxy.Config.admin_url()` returns the
  expected default in dev with no env vars set.

---

- [ ] **Unit 3: `Destila.Proxy.Caddy` admin API client**

**Goal:** Wrap Caddy's admin API with `Req`. Public surface:
`register/2`, `unregister/1`, `preflight/1`, plus `probe/0`. Includes:
host/route-id/scheme computation, basic-auth password hashing (cached
in `:persistent_term`), probe-then-call with silent TCP-failure
no-op, and structured error returns for non-2xx.

**Requirements:** R2, R3, R4, R5, R7, R8.

**Dependencies:** Unit 2 (config accessors).

**Files:**
- Create: `lib/destila/proxy/caddy.ex`
- Test: `test/destila/proxy/caddy_test.exs`
- Modify: `mix.exs` to add `bcrypt_elixir` as a dep (current `mix.exs`
  does not include it; verify and add if missing).
- Modify: `test/test_helper.exs` (no Mimic.copy needed since `Req.Test`
  is the stub; just ensure no regression).

**Approach:**
- Public API:
  - `register(%Target{} = target, port :: integer) :: {:ok, :registered | :no_proxy} | {:error, term}`.
  - `unregister(%Target{} = target) :: :ok | {:error, term}`.
  - `preflight(%Target{} = target) :: :ok | {:error, :missing_credentials}` —
    pure check (no HTTP) that returns `:ok` when the target requires
    no basic auth (project with `basic_auth_enabled: false`, or any
    target where `host_for/1` returns `nil`), or when both
    `basic_auth_user/0` and `basic_auth_password/0` are set; otherwise
    returns `{:error, :missing_credentials}`. Used by ServiceManager's
    pre-tmux preflight branch (Unit 6) so a process is not spawned
    when credentials are missing.
  - `probe() :: :ok | :unreachable`.
- Internal helpers:
  - `route_id(%Target{kind: :project, id: id})` →
    `"destila-project-" <> id`.
  - `route_id(%Target{kind: :session, id: id})` →
    `"destila-session-" <> id`.
  - `host_for(%Target{kind: :session, id: id})` →
    `id <> "." <> Config.base_domain()`.
  - `host_for(%Target{kind: :project, project: %{domain: d}})` →
    trimmed `d` or `nil` (signals "no proxy needed").
  - `scheme_for(host)` → `"http"` if host ends in `".localhost"` or
    is exactly `"localhost"`, else `"https"`. (The advertised scheme;
    not used in route JSON.)
  - `basic_auth_required?(target)` → always true for `:session`;
    for `:project`, the project's `basic_auth_enabled`.
  - `password_hash/0` → hashes
    `Config.basic_auth_password()` once via `Bcrypt.hash_pwd_salt/1`
    and caches in `:persistent_term`. Cache key includes the raw
    password so a runtime change still invalidates.
  - `route_json(target, port, basic_auth?)` → builds the route map per
    Caddy admin schema (see Technical Design below).
- Probe-then-call:
  - `probe/0` does `Req.get(admin_url <> "/config/")` with
    `connect_options: [timeout: 500]` and
    `receive_timeout: 500`. Returns `:ok` on `{:ok, %{status: 200}}`,
    `:unreachable` on `{:error, _}` (any transport error), and
    `:unreachable` on any other status (treat unexpected admin states
    as unreachable for safety).
- `register/2`:
  1. If `host_for/1` returns nil (project with blank domain) → return
     `{:ok, :no_proxy}` immediately.
  2. If `basic_auth_required?(target)` and either credential env var
     is missing → return `{:error, :missing_credentials}`. Caller
     uses this to block start.
  3. Probe; on unreachable → log debug and return `{:ok, :no_proxy}`.
  4. `DELETE /id/<route_id>`. Treat **200 and 404 as success**
     (idempotent cleanup — 404 means the route was not present).
     Any other non-2xx status logs a warning and continues to step 5;
     do not abort, since the subsequent POST will surface a hard
     failure if the route truly cannot be created.
  5. `POST /config/apps/http/servers/srv0/routes` with the route
     JSON. **2xx → `{:ok, :registered}`**; **any non-2xx →
     `{:error, {:caddy_status, status, body}}`** (no warning-and-continue
     here — POST is the authoritative success signal).
- `unregister/1`:
  1. Probe; on unreachable → `{:ok, :no_proxy}` (silent).
  2. `DELETE /id/<route_id>`. **200 and 404 → `:ok`** (idempotent;
     same rationale as `register/2` step 4). **Any other non-2xx →
     `{:error, {:caddy_status, status, body}}`** (caller logs but
     does not block stop — see Unit 6).
- All HTTP via `Req.new(base_url: admin_url, ...)`; merge
  `Config.req_options/0` so tests can inject `plug: {Req.Test,
  Destila.Proxy.Caddy}`.

**Execution note:** Consider implementing `probe/0` and
`route_json/3` test-first — they're pure and easy to specify; the
surrounding HTTP path is then thin glue.

**Technical design:** *(directional guidance, not implementation
specification.)*

Route JSON shape (single-route, basic-auth + reverse-proxy):

```
{
  "@id": "<route_id>",
  "match": [{ "host": ["<host>"] }],
  "handle": [
    {
      "handler": "authentication",      // omitted when basic_auth not required
      "providers": {
        "http_basic": {
          "realm": "Destila",
          "accounts": [
            { "username": "<user>", "password": "<bcrypt-mcf>" }
          ]
        }
      }
    },
    {
      "handler": "reverse_proxy",
      "upstreams": [{ "dial": "127.0.0.1:<port>" }]
    }
  ],
  "terminal": true
}
```

**Patterns to follow:**
- `lib/destila/ai/auth_login.ex:327-336` for the `Req` `case` shape
  on success/error.
- `Req.Test` plug stubbing as the canonical convention going forward.

**Test scenarios:**
- **Happy path:** `route_id/1` for a `:project` target with id
  `"abc-123"` returns `"destila-project-abc-123"`; for a `:session`
  target returns `"destila-session-<id>"`.
- **Happy path:** `host_for/1` for a session target with base domain
  `"example.com"` returns `"<sid>.example.com"`.
- **Happy path:** `host_for/1` for a project target with
  `domain: "myapp.example.com"` returns `"myapp.example.com"`;
  with blank domain returns `nil`.
- **Happy path:** `scheme_for/1` returns `"http"` for `"localhost"`,
  `"x.localhost"`, `"deep.nested.localhost"`; returns `"https"` for
  `"example.com"`, `"x.example.com"`.
- **Happy path:** `register/2` with a project target with no domain
  returns `{:ok, :no_proxy}` and makes zero HTTP calls (verified by a
  `Req.Test` plug that records calls).
- **Happy path:** `register/2` with a session target and reachable
  Caddy + valid creds: makes exactly two HTTP calls in order — DELETE
  `/id/destila-session-<sid>`, then POST
  `/config/apps/http/servers/srv0/routes`. POST body has correct
  `@id`, `match.host`, `terminal: true`, both handlers, basic-auth
  password starting with `$2`.
- **Happy path:** `register/2` for a project target with
  `basic_auth_enabled: false` produces a route JSON whose `handle`
  array has only the `reverse_proxy` handler (no `authentication`).
- **Edge case:** `register/2` returns `{:ok, :registered}` even when
  the prior DELETE returns 404 (idempotent cleanup).
- **Error path:** `register/2` returns `{:error, :missing_credentials}`
  when `basic_auth_user` is `nil` and basic auth is required, and
  makes zero HTTP calls.
- **Error path:** `register/2` returns `{:error, :missing_credentials}`
  when `basic_auth_password` is `nil` and basic auth is required.
- **Error path:** `register/2` for a project with no domain and
  missing creds returns `{:ok, :no_proxy}` regardless of creds (no
  route → no auth check).
- **Error path (silent no-op):** `register/2` returns
  `{:ok, :no_proxy}` and makes only the probe call when the admin URL
  fails at the TCP layer (Req.Test stub returns `{:error, _}`).
- **Error path:** `register/2` returns
  `{:error, {:caddy_status, 400, _}}` when POST returns non-2xx.
- **Happy path:** `unregister/1` returns `:ok` on 200 and on 404.
- **Error path (silent no-op):** `unregister/1` returns `:ok` and
  makes only the probe call when admin URL is unreachable.
- **Error path:** `unregister/1` returns
  `{:error, {:caddy_status, 500, _}}` when DELETE returns 500.
- **Edge case:** Password is hashed exactly once across multiple
  `register/2` calls within the same test (verified via a counter
  hook on `Bcrypt.hash_pwd_salt/1`, or by asserting the same hash
  string appears across requests).
- **Happy path (`preflight/1`):** session target with both
  `basic_auth_user` and `basic_auth_password` configured returns `:ok`
  and makes zero HTTP calls.
- **Happy path (`preflight/1`):** project target with no domain
  returns `:ok` regardless of creds (no route → no auth check) and
  makes zero HTTP calls.
- **Happy path (`preflight/1`):** project target with a domain and
  `basic_auth_enabled: false` returns `:ok` regardless of creds.
- **Error path (`preflight/1`):** session target with
  `basic_auth_password` unset returns
  `{:error, :missing_credentials}` and makes zero HTTP calls.
- **Error path (`preflight/1`):** project target with a domain and
  `basic_auth_enabled: true` and `basic_auth_user` unset returns
  `{:error, :missing_credentials}` and makes zero HTTP calls.

**Verification:**
- `mix test test/destila/proxy/caddy_test.exs` passes with all branches
  covered.
- `Destila.Proxy.Caddy.probe()` returns `:unreachable` in dev with no
  Caddy running.

---

- [ ] **Unit 4: `Destila.Services.Url` advertised-URL helper**

**Goal:** A single, side-effect-free helper that computes the
advertised URL for a project or session given its domain configuration
and registration state. Falls back to `http://localhost:<port>` when
no route is registered.

**Requirements:** R9, R12.

**Dependencies:** Unit 1 (`project.domain`), Unit 2 (`base_domain`).

**Files:**
- Create: `lib/destila/services/url.ex`
- Test: `test/destila/services/url_test.exs`

**Approach:**
- Public API (one function, multiple clauses):
  - `for_session(%{id: _, service_state: state} = ws) :: String.t() | nil`.
  - `for_project(%Project{} = project) :: String.t() | nil`
    (reads `project.service_state` directly).
- Resolution order (per the High-Level flow diagram):
  1. If `state` is nil or `state["status"]` ≠ `"running"` or
     `state["port"]` is not an integer → `nil`.
  2. Compute the localhost URL = `"http://localhost:<port>"`.
  3. If `state["caddy_route"]` is not `true` → return localhost URL.
  4. For sessions: host = `"<id>.<base_domain>"`.
  5. For projects: host = `project.domain` (trimmed), or if blank →
     return localhost URL.
  6. Scheme = `"http"` for hosts in the localhost family; else
    `"https"`. Return `"<scheme>://<host>"`.
- The helper does not consult Caddy at runtime — it relies entirely
  on `service_state["caddy_route"]` being current, which Unit 6 keeps
  in sync.

**Patterns to follow:**
- The current four URL helpers (`running_url/1`, `url_link/1`,
  `service_url/2`, the inline labels) are all small private functions
  that return `nil` for non-running states. Mirror that contract so
  the LiveView call sites change as little as possible.

**Test scenarios:**
- **Happy path:** session with running state, `caddy_route: true`,
  base domain `"example.com"` → `"https://<sid>.example.com"`.
- **Happy path:** session with running state, `caddy_route: true`,
  base domain `"localhost"` → `"http://<sid>.localhost"`.
- **Happy path:** project with running state, `caddy_route: true`,
  `domain: "myapp.example.com"` → `"https://myapp.example.com"`.
- **Happy path:** project with running state, `caddy_route: true`,
  `domain: "x.localhost"` → `"http://x.localhost"`.
- **Edge case (fallback):** project with running state,
  `caddy_route: false`, port 4321 → `"http://localhost:4321"`.
- **Edge case (fallback):** project with running state, no
  `caddy_route` key in state, port 4321 → `"http://localhost:4321"`.
- **Edge case (fallback):** project with running state,
  `caddy_route: true`, blank/nil domain → `"http://localhost:4321"`.
- **Edge case:** stopped state → `nil`.
- **Edge case:** nil `service_state` → `nil`.
- **Edge case:** running state with non-integer port → `nil`.
- **Edge case:** session with running state, `caddy_route: false`,
  port 4321 → `"http://localhost:4321"` (fallback applies even
  though sessions normally always register).
- **Edge case:** project with `domain: "App.Example.COM"` (mixed
  case) → host is preserved as-is in the URL (no
  lowercasing — this matches DNS case-insensitivity practice and
  avoids surprising the user with their stored value).

**Verification:**
- `mix test test/destila/services/url_test.exs` passes.

---

- [ ] **Unit 5: Project form additions for domain + basic_auth_enabled**

**Goal:** Add `domain` (text input) and `basic_auth_enabled`
(checkbox) to the project create + edit form. Plumb errors back from
the changeset so the new hostname validator surfaces in the UI.

**Requirements:** R1.

**Dependencies:** Unit 1.

**Files:**
- Modify: `lib/destila_web/live/project_form_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs` (or add a new
  `project_form_live_test.exs`; follow whichever the existing
  `mise_auto_trust` tests use)

**Approach:**
- In `update/2`'s `assign_new(:form, ...)` map, add
  `"domain" => project.domain || ""` and
  `"basic_auth_enabled" => project.basic_auth_enabled || false`.
- In `handle_event("save", params, socket)`:
  - Add `domain: non_blank(params["domain"])` to `attrs`.
  - Add `basic_auth_enabled: to_bool(params["basic_auth_enabled"])`.
- In `changeset_to_errors/1`, add a clause mapping
  `:domain` errors to `:domain`.
- Render: add a new fieldset for `domain` (text input, optional)
  inside the existing "Service" rounded-box block (since the
  semantics tie to the service URL). Add a checkbox for
  `basic_auth_enabled` immediately below `domain`, mirroring the
  `mise_auto_trust` checkbox pattern (lines 188–208) including the
  hidden `<input type="hidden" name="basic_auth_enabled" value="false" />`
  trick so unchecked values arrive.
- Help text under the `domain` input: "Optional. When set, this
  project's service is reachable at this domain via Caddy."
- Help text under the `basic_auth_enabled` checkbox: "Wrap this
  service in basic auth using the credentials configured in
  `DESTILA_BASIC_AUTH_USER` / `DESTILA_BASIC_AUTH_PASSWORD`."

**Patterns to follow:**
- `lib/destila_web/live/project_form_live.ex:188-208` for the
  checkbox + hidden-input pair pattern (mise_auto_trust).
- `lib/destila_web/live/project_form_live.ex:228-247` for the
  validated text-input fieldset pattern (service_env_var).

**Test scenarios:**
- **Happy path:** create a project with `name`, `local_folder`, and
  `domain: "myapp.example.com"`; persisted project has `domain` set.
- **Happy path:** create a project with `basic_auth_enabled` checked;
  persisted project has it `true`.
- **Happy path:** create a project leaving both blank/unchecked;
  persisted project has `domain: nil` and `basic_auth_enabled: false`.
- **Happy path:** edit a project to set/clear `domain`; persisted
  value updates.
- **Happy path:** edit a project to toggle `basic_auth_enabled`;
  persisted value updates.
- **Error path:** submit an invalid domain (`"app..example.com"`);
  the form shows an inline error and the project is not created.
- **Edge case:** form preserves typed domain on validation error
  (re-render does not blow away the user's input).
- **Integration:** the form fields are present in both the create
  modal and the edit modal (verified by visiting the projects index
  and asserting `element/2` for the input IDs in both modes).

**Verification:**
- `mix test test/destila_web/live/projects_live_test.exs` passes.

---

- [ ] **Unit 6: ServiceManager start/stop/cleanup hooks**

**Goal:** Wire `Destila.Proxy.Caddy` into
`ServiceManager.do_start/1`, `do_stop/1`, and `cleanup_target/1`.
Persist a `caddy_route` flag in `service_state`. Block start when
basic auth is required and creds are missing. Surface non-2xx Caddy
failures via flash on the relevant detail page.

**Requirements:** R2, R3, R5, R6, R7, R8, R11.

**Dependencies:** Units 1, 3.

**Files:**
- Modify: `lib/destila/services/service_manager.ex`
- Modify: `lib/destila/pub_sub_helper.ex` (add a
  `broadcast_service_proxy_error/2` helper, mirroring existing
  per-target broadcast helpers — only if needed)
- Modify: `lib/destila_web/live/service_detail_live.ex` (consume the
  new broadcast → put_flash)
- Modify: `test/test_helper.exs` (add `Mimic.copy(Destila.Proxy.Caddy)`)
- Test: `test/destila/services/service_manager_caddy_test.exs`

**Approach:**
- Insertion sites:
  - **`do_start/1` after `wait_for_port` returns true** (line ~191):
    1. Call `Destila.Proxy.Caddy.register(target, port)`.
    2. On `{:ok, :registered}` → set `running_state["caddy_route"]`
       to `true`.
    3. On `{:ok, :no_proxy}` → set `running_state["caddy_route"]` to
       `false`.
    4. On `{:error, :missing_credentials}` → call `do_stop(target)`,
       return `{:error, "Basic auth is required for this service but
       DESTILA_BASIC_AUTH_USER / DESTILA_BASIC_AUTH_PASSWORD is not
       set"}`. **Do this preflight before `wait_for_port` so the
       local process is not spawned uselessly** — i.e. move the
       `Caddy.register` preflight branch (creds check only) to
       *before* the tmux setup, but only fire the actual `register/2`
       (probe + HTTP) after the port is up.
    5. On `{:error, {:caddy_status, _, _}}` → set
       `running_state["caddy_route"]` to `false`, broadcast a proxy
       error event via PubSub. Service still considered running
       locally; LiveView turns the broadcast into an error flash.
  - **`do_stop/1`** (line ~210), after `Tmux.kill_window`: call
    `Caddy.unregister(target)`. Best-effort; non-2xx logged but does
    not block stop. Set `service_state["caddy_route"]` to `false`.
  - **`cleanup_target/1`** (line 128): also call
    `Caddy.unregister(target)` (after kill, before `LogTailer.stop`).
- **Two-phase preflight in `do_start`:**
  - Phase A (before tmux/port allocation):
    `Caddy.preflight(target)` (defined in Unit 3's public API) —
    pure check that returns `{:error, :missing_credentials}` or `:ok`.
  - Phase B (after `wait_for_port`): the real `register/2` call,
    which does probe + HTTP + idempotent DELETE-then-POST. The
    creds-check inside `register/2` is retained as a defense-in-depth
    guard (returns the same `{:error, :missing_credentials}` if Phase A
    is bypassed by a future caller) but is unreachable on this path.
- Refresh-on-restart: `do_restart/1` already calls
  `do_stop/1` then `do_start/1`. Both already touch Caddy via the
  hooks; no extra logic needed.
- Self-restart path (`ProjectServices.self_restart/1`): unchanged.
  Restart-on-respawn happens via `resume_all/0` → `start/1` →
  `ServiceManager.execute_target` → `do_start/1`, which re-fires the
  Caddy register. Per spec, no boot-time reconciliation, so a
  Destila that booted while Caddy was down stays unregistered until
  the next user-driven start/stop/restart.
- LiveView flash: subscribe to a new `{:service_proxy_error, reason}`
  broadcast on the existing service-detail PubSub topic. On receipt,
  `put_flash(:error, "Caddy failed to register the route: ...")`.

**Execution note:** Start with characterization tests around the
existing `do_start/1`/`do_stop/1` paths so the Caddy hook does not
regress them (the existing
`test/destila/services/service_manager_test.exs` only covers
`build_service_command/4` — a thin layer).

**Patterns to follow:**
- `lib/destila/services/service_manager.ex:187-196` for the
  `persist_session_state` + `broadcast_status` + return pattern.
- `lib/destila/pub_sub_helper.ex` (read it first) for the existing
  per-topic broadcast helpers.

**Test scenarios:**
- **Happy path (matrix corner 1: Caddy reachable, domain set):**
  starting a project service with `domain: "myapp.example.com"` and
  Caddy reachable invokes `Caddy.register/2`, persists
  `service_state["caddy_route"] = true`, and returns running.
- **Happy path (matrix corner 2: Caddy reachable, domain unset):**
  starting a project service with no domain calls
  `Caddy.register/2` which returns `{:ok, :no_proxy}`, persists
  `service_state["caddy_route"] = false`, returns running. (No HTTP
  to Caddy because of the early-return inside `Caddy.register/2`.)
- **Happy path (matrix corner 3: Caddy unreachable, domain set):**
  starting a project service with a domain when the admin URL is
  unreachable persists `caddy_route = false` and returns running;
  no error surfaced.
- **Happy path (matrix corner 4: Caddy unreachable, domain unset):**
  same as corner 2 — no Caddy interaction at all.
- **Happy path:** starting a session service with reachable Caddy
  and configured creds invokes `Caddy.register/2`, persists
  `caddy_route = true`, returns running.
- **Error path (preflight block):** starting a session service when
  `DESTILA_BASIC_AUTH_USER` is unset returns
  `{:error, "Basic auth is required ..."}` and **does not invoke
  any tmux setup** (no `Tmux.ensure_session` call recorded).
- **Error path (preflight block):** starting a project service with
  `basic_auth_enabled: true` and no creds returns the same error
  with no tmux setup.
- **Happy path:** starting a project service with
  `basic_auth_enabled: true` and configured creds passes preflight
  and produces a route with the auth handler in the request.
- **Edge case:** a project service with
  `basic_auth_enabled: true` but no domain skips both preflight (no
  route → no creds needed) and the register call → returns running
  with `caddy_route = false`.
- **Error path (Caddy non-2xx):** when `Caddy.register/2` returns
  `{:error, {:caddy_status, 400, body}}`, `do_start` still returns
  `{:ok, running_state}` with `caddy_route = false`, persists state,
  and broadcasts a `:service_proxy_error` event captured by the
  test process via `Phoenix.PubSub.subscribe`.
- **Happy path:** stopping a registered service invokes
  `Caddy.unregister/1` and persists `caddy_route = false`.
- **Happy path:** stopping a project service with no domain still
  invokes `Caddy.unregister/1` (which is a no-op for no-domain
  targets); state transition correct either way.
- **Edge case:** `do_restart/1` calls `Caddy.unregister/1` then
  `Caddy.register/2` exactly once each, in that order, against the
  same `@id`.
- **Edge case:** `cleanup_target/1` (session archive path) calls
  `Caddy.unregister/1` after killing the tmux window.
- **Integration:** `WorkflowRunnerLive` start path with
  `Mimic.expect(ServiceManager, :execute_target, ...)` already
  works; the new behavior is downstream of that and verified at the
  ServiceManager level.

**Verification:**
- `mix test test/destila/services/service_manager_caddy_test.exs`
  passes all matrix corners + preflight cases.
- Existing `test/destila/services/project_services_test.exs` and
  `test/destila/workflows_test.exs` still pass (no regression in
  lifecycle behavior).

---

- [ ] **Unit 7: Consolidate URL display sites onto `Services.Url`**

**Goal:** Replace the four existing URL-construction call sites with
calls to `Destila.Services.Url`. Update inline labels (e.g.
"localhost:{port}") to display the host portion of the resolved URL
instead, falling back to the port label when on localhost.

**Requirements:** R9, R12.

**Dependencies:** Units 4, 6.

**Files:**
- Modify: `lib/destila_web/live/services_live.ex` (drop
  `running_url/1`, use `Url.for_project`/`Url.for_session`; rework
  inline labels)
- Modify: `lib/destila_web/live/service_detail_live.ex` (rework
  `url_link/1`)
- Modify: `lib/destila_web/live/workflow_runner_live.ex` (rework
  `service_url/2` and the globe-button label/title)
- Modify: existing LiveView tests for the three pages to assert on
  the new URLs in the new scenarios; existing localhost assertions
  stay intact for the no-domain default case.

**Approach:**
- For each site, the change is roughly:
  - `running_url(item)` →
    `Url.for_project(item)` or `Url.for_session(item)` depending on
    the item kind.
  - Inline label inside the anchor: show a short version of the URL.
    For localhost: keep `"localhost:<port>"`. For domain-based: show
    just the host (e.g. `"myapp.example.com"`).
  - Anchor `href`/`title` use the full URL from the helper.
- The structural anchor markup stays identical (id, classes,
  target/rel attrs), so existing LiveView selector-based tests keep
  passing.
- Streams: in `services_live.ex`, when a project's domain or
  `basic_auth_enabled` change, the existing
  `:project_updated` broadcast already triggers a refresh; verified
  via the existing `refresh/1` path.

**Patterns to follow:**
- `services_live.ex:201-213` row anchor structure stays as the
  template; only the URL/label expressions change.
- `service_detail_live.ex:643-667` `url_link/1` keeps its
  `id="service-url-link"`.
- `workflow_runner_live.ex:1133-1144` keeps
  `id="service-open-url-link"` and the globe icon.

**Test scenarios:**
- **Happy path:** services index row for a project with
  `domain: "myapp.example.com"` and `caddy_route: true` shows an
  anchor whose `href` is `"https://myapp.example.com"` and whose
  visible text is `"myapp.example.com"`.
- **Happy path:** services index row for a project with no domain
  and `caddy_route: false` shows
  `href="http://localhost:<port>"` and label `"localhost:<port>"`
  (existing behavior, unchanged).
- **Happy path:** services index row for a session shows
  `href="https://<sid>.<base_domain>"` when registered.
- **Happy path:** services index row for a session falls back to
  `http://localhost:<port>` when `caddy_route: false`.
- **Happy path:** service detail page for a registered project
  service shows the domain URL link.
- **Happy path:** service detail page for an unregistered project
  service shows the localhost URL link.
- **Happy path:** workflow-runner sidebar globe button `href` is
  the registered URL (when registered) or the localhost URL (when
  not).
- **Edge case:** when `service_state["caddy_route"]` is
  `false` because the registration failed with non-2xx, the
  advertised URL is the localhost fallback (and a previous flash
  surfaced the error — verified in Unit 6).
- **Integration:** `:project_updated` broadcast after editing the
  domain in the form re-renders the row with the new URL (verified
  end-to-end in `services_live_test.exs`).

**Verification:**
- `mix test test/destila_web/live/services_live_test.exs`,
  `service_detail_live_test.exs`,
  `workflow_runner_live_test.exs` all pass.
- Manual smoke check in dev: with no domain configured, the URL
  shown is still `http://localhost:<port>`; with a domain
  configured and Caddy reachable, the URL is the domain.

---

- [ ] **Unit 8: Gherkin updates and end-to-end feature linkage**

**Goal:** Capture the cross-cutting reverse-proxy behavior in a new
feature file and tighten the existing service-related feature files.
Make sure every new scenario has at least one linked test.

**Requirements:** R12.

**Dependencies:** Units 1, 5, 6, 7.

**Files:**
- Create: `features/caddy_proxy.feature`
- Modify: `features/project_management.feature` (prose mentions
  `domain` and `basic_auth_enabled`; new scenarios for create + edit;
  domain-optional + non-unique scenarios)
- Modify: `features/project_service.feature` (start triggers Caddy
  register when domain set; stop triggers unregister; start with no
  domain makes no Caddy calls; prose mentions silent skip when admin
  unreachable)
- Modify: `features/service_detail_page.feature` (tighten existing
  localhost-URL scenarios with explicit "no configured domain"
  precondition; new scenarios for domain URL — https for
  non-localhost, http for `*.localhost` — and localhost fallback when
  Caddy unreachable)
- Modify: `features/services_index.feature` (same tightening +
  domain/session URL scenarios + fallback)
- Modify: `features/service_status_sidebar.feature` (same tightening
  + globe button shows domain URL when registered)
- Modify: corresponding `*_test.exs` files to add `@tag feature: ...,
  scenario: "..."` annotations matching every new scenario.

**Approach:**
- Each modified feature file gets a small prose update at the top
  explaining the new optional fields / behavior.
- Every new scenario in the new `caddy_proxy.feature` is owned by a
  test in either `service_manager_caddy_test.exs` (Unit 6) or
  `caddy_test.exs` (Unit 3); cross-cutting scenarios may be linked
  to multiple tests.
- Tightening the existing localhost scenarios:
  - Add "Given the project has no configured domain" (or
    equivalent) to the Given clauses of the existing localhost-URL
    scenarios in `service_detail_page.feature`,
    `services_index.feature`, `service_status_sidebar.feature`.

**Patterns to follow:**
- Existing feature files for prose tone, scenario phrasing, and the
  Given/When/Then style.
- `AGENTS.md` lines 112–120 for the `@tag` convention.

**Test scenarios:** *(scenario set for the new
`features/caddy_proxy.feature`; each is owned by a corresponding
test in Unit 3 or Unit 6.)*

- Scenario: Project service start registers a Caddy route with a
  deterministic `@id` when domain is set.
- Scenario: Project service start makes no Caddy calls when no domain
  is set.
- Scenario: Project service start wraps the route in basic auth when
  `basic_auth_enabled` is true.
- Scenario: Project service start does not wrap the route in basic
  auth when `basic_auth_enabled` is false.
- Scenario: Session service start always registers a route at
  `<session_id>.<base_domain>`.
- Scenario: Session service start always wraps the route in basic
  auth.
- Scenario: Service start blocks with a clear error when basic auth
  is required and credentials are missing.
- Scenario: Domain-based URL uses `https` for non-localhost hosts.
- Scenario: Domain-based URL uses `http` for `*.localhost` hosts.
- Scenario: Service stop unregisters the route via `DELETE
  /id/<route_id>`.
- Scenario: Service restart deletes then re-adds the route under the
  same `@id`.
- Scenario: Register is a silent no-op when the Caddy admin URL is
  unreachable.
- Scenario: Unregister is a silent no-op when the Caddy admin URL is
  unreachable.
- Scenario: A non-2xx response from Caddy on register surfaces an
  error flash on the service detail page.
- Scenario: The Caddy admin URL is configurable via
  `DESTILA_CADDY_ADMIN_URL`.
- Scenario: Destila does not perform boot-time route reconciliation.
- Scenario: Two projects sharing the same domain both register their
  routes (last successful register wins on the Caddy side).

**Verification:**
- `mix test --only feature:caddy_proxy` runs every linked test
  successfully.
- `mix precommit` passes overall.
- `grep -L '@tag feature:' features/caddy_proxy.feature` produces no
  scenarios without at least one corresponding `@tag` in test files
  (verified by manual cross-reference; there is no automated linter
  for this).

## System-Wide Impact

- **Interaction graph:** New side-effects in
  `ServiceManager.do_start/do_stop/cleanup_target` propagate to:
  every LiveView and AI-tool call site enumerated in research
  (`service_detail_live.ex`, `workflow_runner_live.ex`, `tools.ex`,
  `project_services.ex`, `workflows.ex`). All of them route through
  the same seam, so behavior is uniform.
- **Error propagation:** `{:error, :missing_credentials}` becomes a
  user-visible error string returned from
  `ServiceManager.execute_target/2` — every existing caller that
  pattern-matches on `{:ok, _} | {:error, msg}` already handles
  this. Non-2xx Caddy responses propagate via a new PubSub message
  type, consumed only by `service_detail_live.ex`; other consumers
  of the existing service topic ignore unknown messages safely
  (verified in research).
- **State lifecycle risks:**
  - `service_state["caddy_route"]` can drift from reality if Caddy
    state is mutated outside Destila (e.g. user manually deletes a
    route via `caddy adapt`). This is acceptable per spec — Destila
    only re-touches routes on subsequent start/stop/restart events.
  - A Destila crash between successful local start and successful
    Caddy register leaves the local process running with no route
    registered — same as Caddy being unreachable (URL falls back to
    localhost). The next stop call still tries to unregister; a 404
    is treated as success.
- **API surface parity:** the AI-tool layer (`Destila.AI.Tools`)
  uses `ServiceManager.execute/3` and `execute_target/2` directly.
  Both surface the same `{:error, msg}` shape used by LiveViews, so
  a missing-creds error is visible to the AI agent in tool output.
- **Integration coverage:** Unit 6 explicitly covers all four
  matrix corners (Caddy reachable/unreachable × domain set/unset)
  plus the missing-creds preflight, exercised end-to-end through
  `ServiceManager.do_start` with `Req.Test` stubs. Unit 7
  integration tests cover broadcast → URL refresh.
- **Unchanged invariants:**
  - Existing `service_state` shape (`status`, `port`, `run_command`,
    `setup_command`, `last_pulled_at`, `default_branch`) is
    preserved; we only *add* a `caddy_route` key.
  - `Project.webservice?/1` is unchanged. Domain alone does not make
    a project a webservice.
  - Self-hosted (`local_folder` canonicalizes to BEAM cwd) restart
    flow continues to work: the resume hook re-fires `start/1`,
    which re-registers via the standard hook.
  - All existing localhost-only scenarios still pass for projects
    without a configured domain.

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `srv0` is not the actual Caddy server name on a user's setup, so POSTs 404 | Med | Med | Surface `srv0` as a documented assumption in the README addition; add a clear error path that treats POST 404 as `{:error, {:caddy_status, 404, body}}` and surfaces it as a flash, so a misconfigured user sees a real message instead of a silent localhost fallback. Future enhancement (out of scope): `DESTILA_CADDY_SERVER_NAME` env var. |
| `bcrypt_elixir` not in deps; introducing it changes the dep tree | Low | Low | Confirm in Unit 3; if absent, add as a runtime dep. Already a common Phoenix-stack dep; no compile-time concern. |
| `Req.Test` plug stubbing introduces a new pattern not yet used in the codebase | Low | Low | Document the pattern in the new test file's `@moduledoc`; keep the Application-env injection seam so a future move back to Mimic is trivial. |
| First-call latency from bcrypt hashing on the request hot path | Low | Low | `:persistent_term` cache; cost factor 12 hashes in <100ms on commodity hardware; bcrypt fires at most once per BEAM run per credential change. |
| Two projects sharing the same domain trample each other's routes | Low | Low | Spec accepts this; "last successful register wins on the Caddy side." Documented in the Gherkin scenario. |
| Caddy admin port closed at start time but reachable later → service runs on localhost forever (no reconciliation) | Med | Low | Spec explicitly accepts this. User can trigger a restart to re-register. |
| Self-hosted restart path (System.stop(0) → resume_all → start) re-fires Caddy register; if Caddy is hosted on the same Destila BEAM, it could be restarting at the same time | Low | Low | The probe's silent-no-op path absorbs this; the next user-triggered start/stop touches Caddy again once it's up. |
| Hostname validator is too strict and rejects valid domains users care about (e.g. internationalized domains) | Low | Low | Spec is explicit about RFC-1123 strict; punycode-encoded IDNs pass strict validation. Document this if it surfaces. |
| Adding `domain` and `basic_auth_enabled` to `Project.changeset/2` breaks existing test fixtures that pass full attribute maps | Low | Low | Defaults make both fields optional; existing fixtures don't need to change. Verify across `test/destila/projects_test.exs` etc. as part of Unit 1. |

## Documentation / Operational Notes

- **README addition (in this PR):** a short "Caddy reverse proxy"
  section under existing setup docs explaining the four env vars,
  the assumption that the user has a Caddy server named `srv0`
  listening on `:80` (and `:443` for non-localhost domains), and a
  one-line note that no Caddy is required if `DESTILA_BASE_DOMAIN`
  is left at `"localhost"` and no project has a `domain` configured.
- **Operational behavior to communicate:** Destila is fail-soft on
  Caddy. A misconfigured `DESTILA_CADDY_ADMIN_URL` produces no
  user-visible errors except on actual non-2xx responses. Users who
  expect routing and don't see it should check
  `Destila.Proxy.Caddy.probe()` in `iex` first.
- **No migration data backfill required.** Existing rows get
  `domain: nil` (default for nullable string) and
  `basic_auth_enabled: false` (column default). Both are spec-correct
  defaults.
- **No rollback concern.** The migration is purely additive; reverting
  the code without reverting the migration leaves two unused columns,
  harmless. Reverting both works as long as no production rows have
  set the new fields.

## Sources & References

- User-supplied requirements (this plan's source of truth): the prompt
  body of the planning request initiated 2026-04-27.
- Closest prior plan: `docs/plans/2026-04-24-003-feat-project-level-services-plan.md`
  (project-level services lifecycle).
- Service URL display origin plans:
  `docs/plans/2026-04-24-001-feat-service-detail-page-plan.md`,
  `docs/plans/2026-04-24-002-feat-services-index-page-plan.md`.
- Project schema field precedent:
  `docs/plans/2026-04-22-003-feat-project-mise-auto-trust-plan.md` and
  `priv/repo/migrations/20260422180425_add_mise_auto_trust_to_projects.exs`.
- HTTP integration precedent:
  `lib/destila/ai/auth_login.ex:339`,
  `docs/plans/2026-04-25-001-feat-claude-auth-login-modal-plan.md`.
- Existing service code:
  `lib/destila/services/service_manager.ex`,
  `lib/destila/services/target.ex`,
  `lib/destila/services/project_services.ex`.
- Existing URL display sites:
  `lib/destila_web/live/services_live.ex`,
  `lib/destila_web/live/service_detail_live.ex`,
  `lib/destila_web/live/workflow_runner_live.ex`.
- External documentation (Caddy 2.x):
  - <https://caddyserver.com/docs/api>
  - <https://caddyserver.com/docs/api-tutorial>
  - <https://caddyserver.com/docs/automatic-https>
  - <https://caddyserver.com/docs/caddyfile/directives/basic_auth>
  - <https://caddyserver.com/docs/json/apps/http/servers/routes/>
- Project Gherkin convention: `AGENTS.md` lines 112–120,
  `docs/plans/2026-04-15-003-feat-gherkin-phase-structured-tools-plan.md`.
