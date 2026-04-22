Feature: Post-Completion Follow-Up Modal
  When a user marks a workflow session as done, they are offered immediate
  follow-up options: starting a compatible follow-up workflow (which archives
  the current session), archiving only, or dismissing. The existing
  "Workflow complete" banner and top-of-page Archive button remain
  independently usable.

  # --- Modal trigger ---

  Scenario: Modal opens immediately after Mark as Done
    Given I am viewing a workflow session whose last phase is complete
    When I click "Mark as Done"
    Then the follow-up modal should open
    And the session should be marked as done

  Scenario: Modal lists all compatible follow-up workflows
    Given I am viewing a completed brainstorm session with an exported prompt
    When I click "Mark as Done"
    Then the modal should show a "Start Implement a Prompt and archive" button
    And the modal should show an "Archive only" button
    And the modal should show a "Close" button

  Scenario: Modal shows no follow-ups when none are compatible
    Given I am viewing a completed session with no compatible exports
    When I click "Mark as Done"
    Then the modal should open
    And no "Start ... and archive" button should be shown
    And an empty-state message should explain there are no follow-ups
    And the modal should show an "Archive only" button and a "Close" button

  # --- Follow-up actions ---

  Scenario: Starting a follow-up auto-creates and navigates to the new session
    Given I am viewing a completed brainstorm session with an exported prompt
    And I click "Mark as Done"
    When I click "Start Implement a Prompt and archive"
    Then a new implement_general_prompt session should be created from the exported prompt
    And the new session should inherit the source session's project
    And the source session should be archived
    And I should be navigated to the new session

  Scenario: Archive only archives without starting a follow-up
    Given I am viewing a completed brainstorm session with an exported prompt
    And I click "Mark as Done"
    When I click "Archive only"
    Then the source session should be archived
    And no new session should be created
    And I should be redirected to the crafting board with a confirmation flash

  Scenario: Close dismisses the modal without archiving or starting a follow-up
    Given I am viewing a completed brainstorm session with an exported prompt
    And I click "Mark as Done"
    When I click "Close"
    Then the modal should be dismissed
    And the session should remain done but not archived
    And no new session should be created

  # --- Existing UI remains available ---

  Scenario: Top-of-page Archive button remains available after closing the modal
    Given I am viewing a completed brainstorm session with an exported prompt
    And I click "Mark as Done"
    And I click "Close"
    When I click the top-of-page "Archive" button
    Then the session should be archived
    And I should be redirected to the crafting board with a confirmation flash
