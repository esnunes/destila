Feature: Claude Auth Login Modal
  When a Claude API call fails with an authentication error, the chat
  surfaces an "auth_error" message bubble with a "Login to Claude" action.
  Clicking the action opens an in-app modal that drives the
  `claude auth login` CLI: it shows a spinner while the CLI starts, then
  the authentication URL with a copy-to-clipboard control and a token
  input form. After the user submits a token, the modal shows a verifying
  state. On success the modal closes and the failed turn is automatically
  retried; on failure the user sees an error and can restart the flow.

  # --- Action surface ---

  Scenario: Login action appears below an auth_error message bubble
    Given I am viewing a workflow session
    And the session has an auth_error message in chat
    Then a "Login to Claude" action should appear below the auth_error bubble
    And no "Login to Claude" action should appear below normal chat bubbles

  # --- Opening the modal ---

  Scenario: Clicking the login action opens the auth modal
    Given I am viewing a workflow session with an auth_error message
    When I click "Login to Claude"
    Then the Claude auth login modal should open
    And the Claude CLI auth login process should be started

  Scenario: Modal shows a loading state while waiting for the URL
    Given I have just opened the Claude auth login modal
    Then the modal should show a "Waiting for the Claude CLI" loading indicator

  Scenario: Modal displays the authentication URL printed by the CLI
    Given the Claude auth login modal is open
    When the CLI prints its authentication URL
    Then the URL should be displayed in the modal
    And a copy-to-clipboard control should be available next to the URL

  # --- Submitting a token ---

  Scenario: User pastes a token and submits it
    Given the Claude auth login modal is showing the authentication URL
    When I paste a token and submit the form
    Then the token should be sent to the Claude CLI
    And the modal should show a "Verifying token" state

  Scenario: Successful token closes the modal and retries the failed turn
    Given the Claude auth login modal is verifying a token
    When the CLI reports a successful login
    Then the modal should close
    And the previously failed AI turn should be retried automatically
    And the Claude CLI auth login process should be stopped

  Scenario: Invalid token shows an error and forces a restart
    Given the Claude auth login modal is verifying a token
    When the CLI reports the token is invalid
    Then the modal should show an error message
    And a "Restart" action should be available
    And the token form should not be shown

  # --- Restart and lifecycle ---

  Scenario: Restarting the flow spawns a new login process
    Given the Claude auth login modal is showing an error
    When I click "Restart"
    Then a new Claude CLI auth login process should be started
    And the modal should display the freshly printed authentication URL

  Scenario: Closing the modal kills the spawned process
    Given the Claude auth login modal is open
    When I close the modal
    Then the modal should be dismissed
    And the Claude CLI auth login process should be stopped

  Scenario: Reopening the modal starts a fresh process
    Given I previously opened and closed the Claude auth login modal
    When I click "Login to Claude" again
    Then a fresh Claude CLI auth login process should be started
    And the modal should not show a stale URL from the previous attempt

  # --- CLI failures ---

  Scenario: CLI process exits before printing a URL
    Given the Claude auth login modal is open
    When the Claude CLI exits before printing a URL
    Then the modal should show a CLI failure message
    And a "Restart" action should be available
