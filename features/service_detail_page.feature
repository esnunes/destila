Feature: Service Detail Page
  The /services/sessions/:id and /services/projects/:id pages offer dedicated
  views of a development service. Both routes mount the same LiveView, branched
  on `live_action` (`:session` vs `:project`). The page shows status, port,
  URL, configured commands and a live tail of the service log, plus lifecycle
  controls (Start, Stop, Restart, Clear logs).

  The :project branch additionally exposes:
    * a "Pull latest & restart" button that fetches the default branch,
      fast-forwards, and restarts the service
    * a self-hosted notice banner when the project's local_folder
      canonicalizes to the BEAM's current working directory (i.e. Destila
      itself)
    * a "Remove service" control that clears service_state and cleans up
      tmux + log files
    * details for "Default branch", "Last pulled", and "Working directory"

  The page is only available for projects that are webservices (i.e. have
  both a run_command and a service_env_var). Logs are captured via tmux
  pipe-pane, streamed to the browser through a per-target log tailer and
  PubSub topic, and rendered in an xterm.js terminal emulator so ANSI escape
  sequences display correctly.

  Scenario: Running service renders status, port, URL, and commands
    Given I visit the service detail page for a running service
    Then I should see the service URL pointing at http://localhost:<port>
    And I should see the configured run_command
    And I should see the configured setup_command
    And I should see the allocated port

  Scenario: Setup command block hidden when blank
    Given I visit the service detail page for a project with no setup_command
    Then the setup command block should not be present
    And the run command block should be visible

  Scenario: Stopped service exposes Start and Clear logs controls
    Given I visit the service detail page for a stopped service
    Then I should see a Start button
    And I should see a Clear logs button
    And I should not see Stop or Restart buttons
    And I should not see the service URL link

  Scenario: Running service exposes Stop, Restart, and Clear logs controls
    Given I visit the service detail page for a running service
    Then I should see a Stop button
    And I should see a Restart button
    And I should see a Clear logs button
    And I should not see a Start button

  Scenario: Clear logs button visible in both stopped and running states
    Given I visit the service detail page for a stopped service
    Then I should see a Clear logs button
    Given I visit the service detail page for a running service
    Then I should see a Clear logs button

  Scenario: Back link returns to the services index
    Given I visit the service detail page for a workflow session
    Then I should see a back link that navigates to /services

  Scenario: Details sidebar links to the associated session
    Given I visit the service detail page for a workflow session
    Then the details sidebar should show a link that navigates to /sessions/<session_id>

  Scenario: Initial log file contents are sent to the terminal on mount
    Given the service log file contains some bytes
    When I visit the service detail page and the terminal signals ready
    Then the server should push those bytes to the terminal as a single output event

  Scenario: New log bytes stream into the terminal
    Given I am on the service detail page with the terminal ready
    When a new chunk of log output is broadcast
    Then the server should push those bytes to the terminal as an output event

  Scenario: Log bytes buffer until the terminal signals ready
    Given I am on the service detail page and the terminal has not yet signaled ready
    When a chunk of log output is broadcast
    Then no output event should be pushed yet
    And once the terminal signals ready the buffered bytes should be pushed as an output event

  Scenario: Clear logs resets the terminal
    Given I am on the service detail page
    When the logs are cleared
    Then the server should push a clear event to the terminal

  Scenario: Logs survive a page reload
    Given the service log file contains some bytes
    When I reload the service detail page and the terminal signals ready
    Then the server should push the file contents to the terminal as an output event

  Scenario: Status update from PubSub refreshes the header
    Given I am on the service detail page
    When a service_status broadcast reports the service as running with a port
    Then the page should show the corresponding localhost URL link

  Scenario: Workflow session update refreshes service state on the detail page
    Given I am on the service detail page
    When the underlying workflow session is updated with new service_state
    Then the page should reflect the new service_state

  Scenario: Returns 404 for unknown session id
    Given I visit /services/sessions/<id> with an id that does not exist
    Then the response status should be 404

  Scenario: Returns 404 for session with no project
    Given I visit the service detail page for a workflow session without a project
    Then the response status should be 404

  Scenario: Returns 404 for project without run_command
    Given I visit the service detail page for a project without a run_command
    Then the response status should be 404

  Scenario: Returns 404 for project without service_env_var
    Given I visit the service detail page for a project without a service_env_var
    Then the response status should be 404

  Scenario: Project branch shows a "Pull latest & restart" button
    Given I visit /services/projects/<project_id> for a project-level service
    Then I should see a "Pull latest & restart" button

  Scenario: Session branch does NOT show a "Pull latest & restart" button
    Given I visit /services/sessions/<session_id> for a session-level service
    Then I should not see a "Pull latest & restart" button

  Scenario: Self-hosted Destila project renders the supervisor notice banner
    Given the project's local_folder canonicalizes to the BEAM's cwd
    When I visit /services/projects/<project_id>
    Then I should see a self-hosted notice banner

  Scenario: Pull failure surfaces an error flash on the detail page
    Given I am on /services/projects/<project_id>
    When a {:project_service_error, :dirty, _} broadcast is received
    Then the page should display an error flash describing the dirty working tree

  Scenario: Project detail page exposes a "Remove service" control
    Given I visit /services/projects/<project_id> for a project-level service
    Then I should see a "Remove service" button
    When I click "Remove service"
    Then the project's service_state should be cleared
    And I should be navigated back to /services
