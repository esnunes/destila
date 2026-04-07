Feature: Crafting Board
  The Crafting Board displays all sessions in the crafting stage. By default,
  sessions are shown as a sectioned list: Setup, Waiting for You, AI Processing,
  In Progress, and Done. Users can toggle "Group by Workflow" to see a read-only
  board per workflow type with phase-based columns. A project filter narrows the view.

  Background:
    Given I am logged in

  # --- Default List View ---

  Scenario: View sessions in sectioned list
    Given there are sessions in various phases and statuses
    When I navigate to the crafting board
    Then I should see five sections: "Setup", "Waiting for You", "AI Processing", "In Progress", and "Done"
    And sessions with no phase execution should appear under "Processing" (setup)
    And sessions with awaiting_input or awaiting_confirmation phase execution should appear under "Waiting for You"
    And sessions with processing phase execution should appear under "Processing"
    And sessions marked as done should appear under "Done"
    And remaining sessions should appear under "Processing"

  Scenario: Session card displays title, project, and phase
    Given there is a session with title "Fix login bug", project "destila", and steps completed 2
    When I navigate to the crafting board
    Then the session card should show the title "Fix login bug"
    And the card should show the project name "destila"
    And the card should show the current phase name

  Scenario: Click session card to navigate to detail page
    Given there is a session on the crafting board
    When I click the session title on the card
    Then I should be navigated to the session detail page

  Scenario: Click project name on card to filter by project
    Given there are sessions for projects "destila" and "other-project"
    When I click the project name "destila" on a session card
    Then only sessions belonging to project "destila" should be shown
    And the project filter should show "destila" as selected

  # --- Project Filter ---

  Scenario: Filter sessions by project
    Given there are sessions for projects "destila" and "other-project"
    When I select "destila" from the project filter
    Then only sessions belonging to project "destila" should be shown

  Scenario: Clear project filter
    Given the project filter is set to "destila"
    When I clear the project filter
    Then sessions from all projects should be shown

  # --- Group by Workflow ---

  Scenario: Toggle group by workflow
    Given there are sessions with different workflow types
    When I toggle "Group by Workflow"
    Then I should see a separate board for each workflow type with sessions
    And each board should have columns matching the phase names of its workflow type
    And sessions should appear in the column matching their current phase

  Scenario: Boards are read-only (no drag and drop)
    Given "Group by Workflow" is active
    Then I should not see any drag-and-drop handles on the boards

  Scenario: Empty workflow boards are hidden
    Given there are only "Brainstorm Idea" sessions on the crafting board
    When I toggle "Group by Workflow"
    Then I should see only the "Brainstorm Idea" workflow board
    And I should not see "New Project" or "Generic Prompt" boards

  Scenario: Filter by project with group by workflow active
    Given "Group by Workflow" is active
    And there are sessions for projects "destila" and "other-project"
    When I select "destila" from the project filter
    Then only sessions belonging to "destila" should be shown across all workflow boards
    And workflow boards with no matching sessions should be hidden

  # --- Aliveness Indicator ---

  Scenario: Session card shows green indicator when Claude Code GenServer is running
    Given there is a session with an active Claude Code GenServer
    When I navigate to the crafting board
    Then the session card should show a green aliveness indicator

  Scenario: Session card shows gray indicator when GenServer is not running and not expected
    Given there is a session whose Claude Code GenServer is not running
    And the session is not in an AI-related phase or not in processing status
    When I navigate to the crafting board
    Then the session card should show a gray aliveness indicator

  Scenario: Session card shows red indicator when GenServer is unexpectedly not running
    Given there is a session in an AI-related phase with processing status
    And the session's Claude Code GenServer is not running
    When I navigate to the crafting board
    Then the session card should show a red aliveness indicator

  Scenario: Session card indicator updates when GenServer stops
    Given I am on the crafting board
    And a session has a running Claude Code GenServer with a green indicator
    When the Claude Code GenServer for that session stops
    Then the session card indicator should change from green to the appropriate state
