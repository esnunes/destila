Feature: Crafting Board
  The Crafting Board displays all prompts in the crafting stage. By default,
  prompts are shown as a sectioned list: Setup, Waiting for Reply, In Progress,
  and Done. Users can toggle "Group by Workflow" to see a read-only board per
  workflow type with phase-based columns. A project filter narrows the view.

  Background:
    Given I am logged in

  # --- Default List View ---

  Scenario: View prompts in sectioned list
    Given there are prompts in various phases and statuses
    When I navigate to the crafting board
    Then I should see four sections: "Setup", "Waiting for Reply", "In Progress", and "Done"
    And prompts with phase_status "setup" should appear under "Setup"
    And prompts with phase_status "conversing" or "advance_suggested" should appear under "Waiting for Reply"
    And prompts marked as done should appear under "Done"
    And remaining prompts should appear under "In Progress"

  Scenario: Prompt card displays title, project, and phase
    Given there is a prompt with title "Fix login bug", project "destila", and steps completed 2
    When I navigate to the crafting board
    Then the prompt card should show the title "Fix login bug"
    And the card should show the project name "destila"
    And the card should show the current phase name (e.g. "Feature Type" for step 2 of Feature Request)

  Scenario: Click prompt card to navigate to detail page
    Given there is a prompt on the crafting board
    When I click the prompt title on the card
    Then I should be navigated to the prompt detail page

  Scenario: Click project name on card to filter by project
    Given there are prompts for projects "destila" and "other-project"
    When I click the project name "destila" on a prompt card
    Then only prompts belonging to project "destila" should be shown
    And the project filter should show "destila" as selected

  # --- Project Filter ---

  Scenario: Filter prompts by project
    Given there are prompts for projects "destila" and "other-project"
    When I select "destila" from the project filter
    Then only prompts belonging to project "destila" should be shown

  Scenario: Clear project filter
    Given the project filter is set to "destila"
    When I clear the project filter
    Then prompts from all projects should be shown

  # --- Group by Workflow ---

  Scenario: Toggle group by workflow
    Given there are prompts with different workflow types
    When I toggle "Group by Workflow"
    Then I should see a separate board for each workflow type with prompts
    And each board should have columns matching the phase names of its workflow type
    And prompts should appear in the column matching their current phase

  Scenario: Boards are read-only (no drag and drop)
    Given "Group by Workflow" is active
    Then I should not see any drag-and-drop handles on the boards

  Scenario: Empty workflow boards are hidden
    Given there are only chore_task prompts on the crafting board
    When I toggle "Group by Workflow"
    Then I should see only the "Chore/Task" workflow board
    And I should not see "Feature Request" or "Project" boards

  Scenario: Filter by project with group by workflow active
    Given "Group by Workflow" is active
    And there are prompts for projects "destila" and "other-project"
    When I select "destila" from the project filter
    Then only prompts belonging to "destila" should be shown across all workflow boards
    And workflow boards with no matching prompts should be hidden
