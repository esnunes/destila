Feature: Services Index Page
  The /services page lists every development service across all non-archived
  workflow sessions whose project is configured as a webservice (i.e. has both
  a run_command and a service_env_var). Each row shows status, port, session
  title, and project name. When a service is running, the row also exposes a
  clickable localhost:<port> URL that opens in a new tab. Clicking the row
  (outside the URL pill) navigates to the per-session /services/:id detail
  page. Lifecycle controls (Start, Stop, Restart, Clear logs) are NOT on the
  index — they stay on the detail page. The list updates live via PubSub as
  services start/stop and as sessions and projects are created, updated,
  archived, or deleted.

  Scenario: Index lists services for non-archived sessions with webservice projects
    Given two non-archived sessions whose projects are webservices
    And one non-archived session whose project is not a webservice
    When I visit /services
    Then I should see a row for each webservice-backed session
    And I should not see a row for the session whose project is not a webservice

  Scenario: Archived sessions are excluded
    Given a webservice-backed session that is archived
    When I visit /services
    Then I should not see a row for the archived session

  Scenario: Sessions whose project is not a webservice are excluded
    Given a session whose project has no run_command or no service_env_var
    When I visit /services
    Then I should not see a row for that session

  Scenario: Sessions with no project are excluded
    Given a non-archived session with project_id nil
    When I visit /services
    Then I should not see a row for that session

  Scenario: Row shows status, port, session, and project
    Given a running webservice-backed session on port 4321
    When I visit /services
    Then the row should show the status indicator
    And the row should show the port 4321
    And the row should show the session title
    And the row should show the project name

  Scenario: Running service row shows a clickable localhost URL
    Given a running webservice-backed session on port 4321
    When I visit /services
    Then the row should expose an anchor to http://localhost:4321
    And the anchor should have target="_blank" and rel="noopener noreferrer"

  Scenario: Stopped service row hides the URL
    Given a stopped webservice-backed session
    When I visit /services
    Then the row should not expose a localhost URL

  Scenario: Row navigates to the service detail page
    Given a webservice-backed session
    When I visit /services
    Then the row should navigate to /services/<id> when clicked

  Scenario: No inline lifecycle controls in the list
    Given a webservice-backed session
    When I visit /services
    Then the page should not expose Start, Stop, Restart, or Clear logs controls

  Scenario: Empty state when no eligible services exist
    Given no eligible webservice-backed sessions
    When I visit /services
    Then I should see an empty-state message

  Scenario: List updates live when a service starts
    Given I am on the /services page with a stopped webservice-backed session
    When a service_status broadcast reports the service as running with a port
    Then the row should expose a clickable localhost URL

  Scenario: List updates live when a service stops
    Given I am on the /services page with a running webservice-backed session
    When a service_status broadcast reports the service as stopped
    Then the row should no longer expose a localhost URL

  Scenario: Services page is reachable from the top-level navigation
    Given I am on any page in the app
    Then the sidebar should contain a link to /services
