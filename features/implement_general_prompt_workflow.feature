Feature: Implement General Prompt Workflow
  The "Implement a Prompt" workflow takes a user-provided prompt and implements
  it end-to-end through AI-driven planning, coding, reviewing, testing, and
  video recording.

  Session creation and setup are handled by CreateSessionLive before the
  session reaches WorkflowRunnerLive. The workflow progresses through seven phases:
  1. Generate Plan - AI creates an implementation plan (non-interactive)
  2. Deepen Plan - AI optionally deepens the plan (non-interactive)
  3. Work - AI implements the plan (non-interactive)
  4. Review - AI reviews and fixes issues (non-interactive)
  5. Browser Tests - AI runs tests if applicable (non-interactive, optional)
  6. Feature Video - AI records a feature video (non-interactive, optional)
  7. Adjustments - User reviews the PR and requests changes (interactive)

  Scenario: Workflow type selection shows the new workflow
    When I navigate to create a new workflow
    Then I should see "Implement a Prompt" as a workflow option
    And I should see the description "Take a prompt through planning, coding, review, testing, and recording"

  Scenario: Creation form with manual prompt and project selection
    When I navigate to start a new "Implement a Prompt" workflow
    Then I should see tabs for "Select existing" and "Write manually"
    When I switch to the manual prompt tab
    And I enter a prompt manually
    And I select a project
    And I click "Start"
    Then a workflow session should be created with setup status
    And I should be redirected to the session detail page

  Scenario: Creation form with existing session prompt selection
    Given a completed "Brainstorm Idea" session exists
    When I navigate to start a new "Implement a Prompt" workflow
    Then I should see the completed session in the prompt list
    When I select an existing session prompt
    Then the project should be pre-selected from the source session

  Scenario: Creation form requires a prompt
    When I navigate to start a new "Implement a Prompt" workflow
    And I select a project but do not enter a prompt
    And I click "Start"
    Then I should see an error indicating a prompt is required

  Scenario: Creation form requires a project
    When I navigate to start a new "Implement a Prompt" workflow
    And I write a manual prompt but do not select a project
    And I click "Start"
    Then I should see an error indicating a project is required

  Scenario: Phase 1 - Non-interactive AI generates plan
    Given I am on phase 1 of an implementation workflow
    Then I should not see a text input
    And I should see the AI working autonomously
    When the AI completes the plan
    Then the workflow should auto-advance to phase 2

  Scenario: Phase 2 - AI may auto-skip deepening
    Given I am on phase 2 of an implementation workflow
    When the AI determines deeper planning is not needed
    Then the workflow should auto-advance to phase 3

  Scenario: Phase 3 - AI starts a new session for implementation
    Given the planning phases (1-2) are complete
    When phase 3 begins
    Then a new AI session should be created for implementation

  Scenario: Non-interactive phase shows cancel button
    Given a non-interactive phase is running
    Then I should see a "Cancel" button
    When I click "Cancel"
    Then the AI session should be stopped
    And I should see a "Retry" button

  Scenario: Non-interactive phase shows retry on error
    Given a non-interactive phase encountered an error
    Then I should see a "Retry" button
    When I click "Retry"
    Then the AI should restart the phase

  Scenario: Phase 7 - Adjustments phase is interactive
    Given the non-interactive phases are complete
    When I reach the adjustments phase
    Then the AI should create a pull request
    And I should see the worktree path
    And I should see a text input to request changes
    When I request an adjustment
    Then the AI should apply the change and push
    And I can mark the workflow as done when satisfied

  Scenario: Crafting board shows implementation workflow
    Given I have an active implementation workflow
    When I visit the crafting board
    Then I should see the workflow card with the "Implementation" badge
