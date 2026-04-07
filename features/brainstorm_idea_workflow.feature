Feature: Brainstorm Idea Workflow
  The "Brainstorm Idea" workflow uses AI-driven conversational phases
  to refine a coding task into an implementation prompt.

  Session creation and setup are handled by CreateSessionLive before the
  session reaches WorkflowRunnerLive. The workflow progresses through four phases:
  1. Task Description - AI asks clarifying questions about the task
  2. Gherkin Review - AI reviews or proposes BDD feature scenarios
  3. Technical Concerns - AI explores technical approach and trade-offs
  4. Prompt Generation - AI generates the final implementation prompt

  Background:
    Given I am logged in

  Scenario: Creation form collects project and idea
    When I navigate to start a new "Brainstorm Idea" workflow
    Then I should see a form to select a project and describe my idea
    When I select a project and enter my initial idea
    And I click "Start"
    Then a workflow session should be created with setup status
    And I should be redirected to the session detail page

  Scenario: Creation form requires a project
    When I navigate to start a new "Brainstorm Idea" workflow
    And I enter an idea but do not select a project
    And I click "Start"
    Then I should see an error indicating a project is required

  Scenario: Creation form requires an idea
    When I navigate to start a new "Brainstorm Idea" workflow
    And I select a project but leave the idea empty
    And I click "Start"
    Then I should see an error indicating an idea is required

  Scenario: Setup displays progress
    Given I completed the creation form and am on the session detail page
    Then I should see "Preparing workspace..." while the worktree is being created
    And the session should show Phase 1 status

  Scenario: Phase 1 - AI asks clarifying questions
    Given the session has completed setup and is in Phase 1 - Task Description
    Then the AI should ask clarifying questions about the task
    And the progress bar should show "Phase 1/4 - Task Description"
    When I answer the AI's questions
    Then the AI may ask follow-up questions or suggest advancing

  Scenario: Advance to the next phase
    Given the AI suggests advancing from the current phase
    Then I should see a "Continue to Phase N" button
    When I click the continue button
    Then a phase divider should appear in the chat
    And the header should update to show the next phase

  Scenario: Decline phase advance to add more context
    Given the AI suggests advancing from the current phase
    When I click "I have more to add"
    Then the text input should be re-enabled
    And I should be able to continue the conversation in the current phase

  Scenario: Phase 2 - Gherkin Review
    Given the session is in Phase 2 - Gherkin Review
    Then the AI should review or propose Gherkin feature scenarios
    When the user and AI agree on the scenarios
    Then the AI should suggest advancing

  Scenario: Skip Gherkin Review when not applicable
    Given the session is in Phase 2 - Gherkin Review
    When the AI determines Gherkin scenarios are not needed
    Then the phase should be automatically skipped
    And the workflow should advance to Phase 3 - Technical Concerns

  Scenario: Phase 3 - Technical Concerns
    Given the session is in Phase 3 - Technical Concerns
    Then the AI should ask about the technical approach
    When the technical approach is discussed and agreed upon
    Then the AI should suggest advancing

  Scenario: Phase 4 - Prompt Generation and mark as done
    Given the session is in Phase 4 - Prompt Generation
    And the phase is no longer processing
    Then the AI should generate an implementation prompt
    And the prompt should be displayed in a styled card
    When I am satisfied with the generated prompt
    And I click "Mark as Done"
    Then the workflow should be marked as complete

  Scenario: Mark as Done is hidden while last phase is processing
    Given the session is in Phase 4 - Prompt Generation
    And the phase is still processing
    Then I should not see a "Mark as Done" button
    And the session should not be marked as complete

  Scenario: Un-done a completed session
    Given the session is marked as done
    When I click "Reopen"
    Then the workflow should no longer be marked as complete
    And I should see the last phase of the workflow
    And I should be able to continue interacting with the session

  Scenario: Edit session title
    Given I am on a session detail page
    When I click the session title
    Then I should see an inline title editor
    When I change the title and press Enter
    Then the title should be updated

  Scenario: Answer AI with a single-select option
    Given the AI presents options as single-select buttons
    When I click one of the options
    Then the selected option should be sent as my response

  Scenario: Answer AI with multi-select options
    Given the AI presents options as multi-select checkboxes
    When I select multiple options and confirm
    Then the selected options should be sent as my response

  Scenario: Answer AI with a multi-question form
    Given the AI presents multiple questions at once
    When I answer each question in sequence
    And I click "Submit All Answers"
    Then all answers should be sent as a single formatted response

  Scenario: Manually expanded previous phase stays open during updates
    Given the session is in Phase 3 - Technical Concerns
    And Phase 1 - Task Description is collapsed
    When I expand Phase 1 by clicking its header
    And new activity occurs in the current phase
    Then Phase 1 should remain expanded

  Scenario: Manually collapsed current phase stays closed during updates
    Given the session is in Phase 3 - Technical Concerns
    And Phase 3 is expanded by default
    When I collapse Phase 3 by clicking its header
    And new activity occurs in the current phase
    Then Phase 3 should remain collapsed

  # --- Aliveness Indicator ---

  Scenario: Workflow runner shows green indicator when Claude Code GenServer is running
    Given I am on a session detail page
    And the session has an active Claude Code GenServer
    Then I should see a green aliveness indicator in the session header

  Scenario: Workflow runner shows gray indicator when GenServer is not expected
    Given I am on a session detail page
    And the session is not in an AI-related phase or not in processing status
    And the session's Claude Code GenServer is not running
    Then I should see a gray aliveness indicator in the session header

  Scenario: Workflow runner shows red indicator when GenServer is unexpectedly not running
    Given I am on a session detail page
    And the session is in an AI-related phase with processing status
    And the session's Claude Code GenServer is not running
    Then I should see a red aliveness indicator in the session header

  Scenario: Workflow runner indicator updates in real-time when GenServer stops
    Given I am on a session detail page
    And the session has a running Claude Code GenServer with a green indicator
    When the Claude Code GenServer stops
    Then the indicator should update to reflect the current state
