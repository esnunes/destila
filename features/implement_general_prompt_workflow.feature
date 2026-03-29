Feature: Implement General Prompt Workflow
  The "Implement a Prompt" workflow takes a user-provided prompt and implements
  it end-to-end through AI-driven planning, coding, reviewing, testing, and
  video recording. It progresses through eight phases:
  1. Prompt & Project - Wizard collecting prompt selection/entry and project
  2. Setup - Prepares the project environment (repo sync, worktree, title gen)
  3. Generate Plan - AI creates an implementation plan (non-interactive)
  4. Deepen Plan - AI optionally deepens the plan (non-interactive)
  5. Work - AI implements the plan (non-interactive)
  6. Review - AI reviews and fixes issues (non-interactive)
  7. Browser Tests - AI runs tests if applicable (non-interactive, optional)
  8. Feature Video - AI records a feature video (non-interactive)

  Background:
    Given I am logged in

  Scenario: Workflow type selection shows the new workflow
    When I navigate to create a new workflow
    Then I should see "Implement a Prompt" as a workflow option
    And I should see the description "Take a prompt through planning, coding, review, testing, and recording"

  Scenario: Phase 1 - Wizard with manual prompt and project selection
    When I navigate to start a new "Implement a Prompt" workflow
    Then I should see tabs for "Select existing" and "Write manually"
    When I switch to the manual prompt tab
    And I enter a prompt manually
    And I select a project
    And I click "Start Implementation"
    Then a workflow session should be created
    And I should be redirected to the session detail page

  Scenario: Phase 1 - Wizard with existing session prompt selection
    Given a completed "Prompt for a Chore / Task" session exists
    When I navigate to start a new "Implement a Prompt" workflow
    Then I should see the completed session in the prompt list
    When I select an existing session prompt
    Then the project should be pre-selected from the source session

  Scenario: Phase 1 - Wizard requires a prompt
    When I navigate to start a new "Implement a Prompt" workflow
    And I select a project but do not enter a prompt
    And I click "Start Implementation"
    Then I should see an error indicating a prompt is required

  Scenario: Phase 1 - Wizard requires a project
    When I navigate to start a new "Implement a Prompt" workflow
    And I write a manual prompt but do not select a project
    And I click "Start Implementation"
    Then I should see an error indicating a project is required

  Scenario: Phase 2 - Setup skips title generation for source session
    Given I started an implementation from an existing session
    Then the setup phase should not show "Generating title..."
    And the session title should match the source session title

  Scenario: Phase 2 - Setup generates title for manual prompt
    Given I started an implementation with a manual prompt
    Then the setup phase should show "Generating title..."

  Scenario: Phase 3 - Non-interactive AI generates plan
    Given I am on phase 3 of an implementation workflow
    Then I should not see a text input
    And I should see the AI working autonomously
    When the AI completes the plan
    Then the workflow should auto-advance to phase 4

  Scenario: Phase 4 - AI may auto-skip deepening
    Given I am on phase 4 of an implementation workflow
    When the AI determines deeper planning is not needed
    Then the workflow should auto-advance to phase 5

  Scenario: Phase 5 - AI starts a new session for implementation
    Given the planning phases (3-4) are complete
    When phase 5 begins
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

  Scenario: Crafting board shows implementation workflow
    Given I have an active implementation workflow
    When I visit the crafting board
    Then I should see the workflow card with the "Implementation" badge
