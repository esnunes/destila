Feature: Prompt for a Chore / Task Workflow
  The "Prompt for a Chore / Task" workflow uses AI-driven conversational phases
  to refine a coding task into an implementation prompt. It progresses through
  six phases:
  1. Project & Idea - Wizard collecting project selection and initial task description
  2. Setup - Prepares the project environment (repo sync, worktree, title gen)
  3. Task Description - AI asks clarifying questions about the task
  4. Gherkin Review - AI reviews or proposes BDD feature scenarios
  5. Technical Concerns - AI explores technical approach and trade-offs
  6. Prompt Generation - AI generates the final implementation prompt

  Background:
    Given I am logged in

  Scenario: Phase 1 - Wizard collects project and idea
    When I navigate to start a new "Prompt for a Chore / Task" workflow
    Then I should see a form to select a project and describe my idea
    When I select a project and enter my initial idea
    And I click "Start"
    Then a workflow session should be created
    And I should be redirected to the session detail page

  Scenario: Phase 1 - Wizard requires a project
    When I navigate to start a new "Prompt for a Chore / Task" workflow
    And I enter an idea but do not select a project
    And I click "Start"
    Then I should see an error indicating a project is required

  Scenario: Phase 1 - Wizard requires an idea
    When I navigate to start a new "Prompt for a Chore / Task" workflow
    And I select a project but leave the idea empty
    And I click "Start"
    Then I should see an error indicating an idea is required

  Scenario: Phase 2 - Setup displays progress
    Given I completed the wizard and am on the session detail page
    Then I should see the setup progress steps
    And the progress bar should show "Phase 2/6 - Setup"

  Scenario: Phase 3 - AI asks clarifying questions
    Given the session is in Phase 3 - Task Description
    Then the AI should ask clarifying questions about the task
    And the progress bar should show "Phase 3/6 - Task Description"
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

  Scenario: Phase 4 - Gherkin Review
    Given the session is in Phase 4 - Gherkin Review
    Then the AI should review or propose Gherkin feature scenarios
    When the user and AI agree on the scenarios
    Then the AI should suggest advancing

  Scenario: Skip Gherkin Review when not applicable
    Given the session is in Phase 4 - Gherkin Review
    When the AI determines Gherkin scenarios are not needed
    Then the phase should be automatically skipped
    And the workflow should advance to Phase 5 - Technical Concerns

  Scenario: Phase 5 - Technical Concerns
    Given the session is in Phase 5 - Technical Concerns
    Then the AI should ask about the technical approach
    When the technical approach is discussed and agreed upon
    Then the AI should suggest advancing

  Scenario: Phase 6 - Prompt Generation and mark as done
    Given the session is in Phase 6 - Prompt Generation
    Then the AI should generate an implementation prompt
    And the prompt should be displayed in a styled card
    When I am satisfied with the generated prompt
    And I click "Mark as Done"
    Then the workflow should be marked as complete

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

  Scenario: Retry a failed setup step
    Given setup is running for my session
    And a step fails due to an error
    Then I should see the error message for the failed step
    And I should see a "Retry" button
    When I click "Retry"
    Then the failed step should be attempted again

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
