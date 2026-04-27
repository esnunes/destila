Feature: Caddy Reverse Proxy
  Destila integrates with a user-managed Caddy server via its admin HTTP
  API to give development services stable, opt-in URLs and basic-auth
  protection.

  Project services with a non-blank `domain` register a route on the host
  declared in the project. Session services always register a route at
  `<session_id>.<DESTILA_BASE_DOMAIN>` and are always wrapped in basic
  auth.

  Routes carry deterministic `@id`s — `destila-project-<project_id>` for
  project services and `destila-session-<session_id>` for sessions — so
  restart is a clean DELETE-then-POST against the same id.

  Configuration is env-vars-only:
    * DESTILA_BASE_DOMAIN (default "localhost")
    * DESTILA_CADDY_ADMIN_URL (default "http://localhost:2019")
    * DESTILA_BASIC_AUTH_USER, DESTILA_BASIC_AUTH_PASSWORD (no defaults)

  When the Caddy admin URL is unreachable on the pre-call probe, register
  and unregister are silent no-ops; the local service still starts/stops
  and the UI advertises the localhost URL.

  Scenario: Project service start registers a Caddy route with a deterministic @id when domain is set
    Given a project whose `domain` is "myapp.example.com" and Caddy is reachable
    When the project service starts
    Then Destila DELETEs /id/destila-project-<project_id>
    And Destila POSTs /config/apps/http/servers/srv0/routes
      with `@id` "destila-project-<project_id>" and `match.host` ["myapp.example.com"]
    And service_state["caddy_route"] is true

  Scenario: Project service start makes no Caddy calls when no domain is set
    Given a project with no configured `domain`
    When the project service starts
    Then no HTTP calls are made to the Caddy admin API
    And service_state["caddy_route"] is false

  Scenario: Project service start wraps the route in basic auth when basic_auth_enabled is true
    Given a project with `domain` set, `basic_auth_enabled` true, and basic-auth credentials configured
    When the project service starts
    Then the POSTed route's handle array includes the `authentication` handler
    And the bcrypt-hashed credential begins with "$2"

  Scenario: Project service start does not wrap the route in basic auth when basic_auth_enabled is false
    Given a project with `domain` set and `basic_auth_enabled` false
    When the project service starts
    Then the POSTed route's handle array contains only the `reverse_proxy` handler

  Scenario: Session service start always registers a route at <session_id>.<base_domain>
    Given a workflow session whose project is a webservice and Caddy is reachable
    When the session service starts
    Then Destila POSTs a route whose `match.host` is ["<session_id>.<base_domain>"]
    And service_state["caddy_route"] is true

  Scenario: Session service start always wraps the route in basic auth
    Given a session service starting with basic-auth credentials configured
    When the session service starts
    Then the POSTed route's handle array includes the `authentication` handler

  Scenario: Service start blocks with a clear error when basic auth is required and credentials are missing
    Given a service for which basic auth is required
    And DESTILA_BASIC_AUTH_USER or DESTILA_BASIC_AUTH_PASSWORD is unset
    When the service start is invoked
    Then the call returns an error mentioning DESTILA_BASIC_AUTH_USER and DESTILA_BASIC_AUTH_PASSWORD
    And the local process is NOT spawned (no tmux setup occurs)

  Scenario: Domain-based URL uses https for non-localhost hosts
    Given a project service registered at "myapp.example.com" with `caddy_route` true
    When the advertised URL is computed
    Then the URL is "https://myapp.example.com"

  Scenario: Domain-based URL uses http for *.localhost hosts
    Given a session service registered at "<session_id>.localhost" with `caddy_route` true
    When the advertised URL is computed
    Then the URL is "http://<session_id>.localhost"

  Scenario: Service stop unregisters the route via DELETE /id/<route_id>
    Given a running service registered with Caddy
    When the service is stopped
    Then Destila DELETEs /id/<route_id>
    And service_state["caddy_route"] is false

  Scenario: Service restart deletes then re-adds the route under the same @id
    Given a running service registered with Caddy
    When the service is restarted
    Then Destila DELETEs /id/<route_id>
    And Destila POSTs a new route under the same `@id`

  Scenario: Register is a silent no-op when the Caddy admin URL is unreachable
    Given the Caddy admin URL is unreachable at the TCP layer
    When a service is started
    Then the service still becomes running
    And service_state["caddy_route"] is false
    And no error is surfaced to the user

  Scenario: Unregister is a silent no-op when the Caddy admin URL is unreachable
    Given the Caddy admin URL is unreachable at the TCP layer
    When a service is stopped
    Then the service still transitions to stopped
    And no error is surfaced to the user

  Scenario: A non-2xx response from Caddy on register surfaces an error flash on the service detail page
    Given Caddy returns 400 on the route POST
    When the service is started
    Then the local service still becomes running with `caddy_route` false
    And a `:service_proxy_error` event is broadcast on the service topic
    And the service detail page renders an error flash mentioning Caddy

  Scenario: The Caddy admin URL is configurable via DESTILA_CADDY_ADMIN_URL
    Given DESTILA_CADDY_ADMIN_URL is set to a custom URL
    Then Destila.Proxy.Config.admin_url/0 returns that custom URL

  Scenario: Destila does not perform boot-time route reconciliation
    Given Destila boots while Caddy is unreachable
    Then no Caddy admin API calls are made until the next user-driven start/stop/restart

  Scenario: Two projects sharing the same domain both register their routes
    Given two projects with the same `domain` configured
    When both project services are started
    Then both register routes successfully
    And the last successful register wins on the Caddy side
