Feature: Chore/Task AI-Driven Workflow
  The Chore/Task workflow uses AI-driven conversational phases to refine
  a coding task into a prompt. It progresses through four
  phases:
  1. Task Description - AI asks clarifying questions about the task
  2. Gherkin Review - AI reviews or proposes BDD feature scenarios
  3. Technical Concerns - AI explores technical approach and trade-offs
  4. Prompt Generation - AI generates the final prompt

  Background:
    Given I am logged in
    And I have a Chore/Task prompt created through the wizard

  Scenario: Phase 1 - AI asks clarifying questions
    Given the prompt is in Phase 1 - Task Description
    Then the AI should ask clarifying questions about the task
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
    Given the prompt is in Phase 2 - Gherkin Review
    Then the AI should review or propose Gherkin feature scenarios
    When the user and AI agree on the scenarios
    Then the AI should suggest advancing

  Scenario: Skip Gherkin Review when not applicable
    Given the prompt is in Phase 2 - Gherkin Review
    When the AI determines Gherkin scenarios are not needed
    Then the phase should be automatically skipped
    And a phase divider should appear in the chat
    And the workflow should advance to Phase 3 - Technical Concerns

  Scenario: Phase 3 - Technical Concerns
    Given the prompt is in Phase 3 - Technical Concerns
    Then the AI should ask about the technical approach
    When the technical approach is discussed and agreed upon
    Then the AI should suggest advancing

  Scenario: Phase 4 - Prompt Generation and mark as done
    Given the prompt is in Phase 4 - Prompt Generation
    Then the AI should generate a prompt
    And the prompt should be displayed in a styled card
    When I am satisfied with the generated prompt
    And I click "Mark as Done"
    Then the workflow should be marked as complete
    And the prompt should move to the done column

