Feature: Create Session Wizard
  The Create Session wizard guides the user through a three-step flow:
  1. Choose a workflow type (Prompt for a Chore / Task, Prompt for a New Project, or Implement a Generic Prompt)
  2. Link a project (select existing or create new)
  3. Describe the initial idea
  After completing the wizard, the user can save and continue to the chat,
  or save and close to return to their previous page.

  Background:
    Given I am logged in

  Scenario: Complete the wizard with Save & Continue
    When I navigate to the new session page
    Then I should see three step indicators
    And I should see three workflow type options: "Prompt for a Chore / Task", "Prompt for a New Project", and "Implement a Generic Prompt"
    When I select one of the workflow types
    Then I should be on step 2
    And I should see a project selection interface
    When I select an existing project
    And I click "Continue"
    Then I should be on step 3
    And I should see the initial idea question
    When I enter an initial idea
    And I click "Save & Continue"
    Then a new session should be created linked to the selected project
    And the session title should be AI-generated based on the user input
    And I should be redirected to the session detail page
    And the chat should show the initial idea as the first user message

  Scenario: Complete the wizard with Save & Close
    When I navigate to the new session page from the crafting board
    And I select one of the workflow types
    And I complete the project step
    Then I should be on step 3
    When I enter an initial idea
    And I click "Save & Close"
    Then a new session should be created linked to the selected project
    And the session title should be AI-generated based on the user input
    And I should be redirected to the crafting board

  Scenario: Create a new project inline during step 2
    When I navigate to the new session page
    And I select one of the workflow types
    Then I should be on step 2
    When I create a new project
    Then the new project should be selected
    When I click "Continue"
    Then I should be on step 3

  Scenario: Project is required for non-"Prompt for a New Project" workflow types
    When I navigate to the new session page
    And I select a non-"Prompt for a New Project" workflow type
    Then I should be on step 2
    And the "Skip" button should not be available
    When I click "Continue" without selecting a project
    Then I should see an error message indicating a project is required
    And I should remain on step 2

  Scenario: Skip project for "Prompt for a New Project" workflow type
    When I navigate to the new session page
    And I select the "Prompt for a New Project" workflow type
    Then I should be on step 2
    When I click "Skip"
    Then I should be on step 3
    And the session should not be linked to a project when saved

  Scenario: Attempt to save without an initial idea
    When I navigate to the new session page
    And I select one of the workflow types
    And I complete the project step
    Then I should be on step 3
    When I click "Save & Continue" without entering an idea
    Then I should see an error message asking me to describe my initial idea
    And I should remain on step 3
    And no session should be created

  Scenario: Navigate back from step 3 to step 2
    When I navigate to the new session page
    And I select one of the workflow types
    And I complete the project step
    Then I should be on step 3
    When I click "Back"
    Then I should be on step 2
    And I should see a project selection interface

  Scenario: Navigate back from step 2 to step 1
    When I navigate to the new session page
    And I select one of the workflow types
    Then I should be on step 2
    When I click "Back"
    Then I should be on step 1
    And I should see three workflow type options: "Prompt for a Chore / Task", "Prompt for a New Project", and "Implement a Generic Prompt"
