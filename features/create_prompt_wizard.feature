Feature: Create Prompt Wizard
  The Create Prompt wizard guides the user through a three-step flow:
  1. Choose a workflow type (Feature Request or Project)
  2. Optionally link a repository URL
  3. Describe the initial idea
  After completing the wizard, the user can save and continue to the chat,
  or save and close to return to their previous page.

  Background:
    Given I am logged in

  Scenario: Create a Feature Request prompt with Save & Continue
    When I navigate to the new prompt page
    Then I should see three step indicators
    And I should see two workflow type options: "Feature Request" and "Project"
    When I select "Feature Request"
    Then I should be on step 2
    And I should see a repository URL input field
    When I enter "https://github.com/owner/repo" in the repository URL field
    And I click "Continue"
    Then I should be on step 3
    And I should see the initial idea question for a Feature Request
    When I enter "Users need a way to export reports as PDF" as the initial idea
    And I click "Save & Continue"
    Then a new prompt should be created with the initial idea pre-populated
    And the prompt title should be AI-generated based on the user input
    And I should be redirected to the prompt detail page
    And the chat should show the initial idea as the first user message
    And the chat should show the step 2 question ready for input

  Scenario: Create a Project prompt with Save & Close
    When I navigate to the new prompt page from the crafting board
    And I select "Project"
    Then I should be on step 2
    When I click "Skip"
    Then I should be on step 3
    And I should see the initial idea question for a Project
    When I enter "A task management app for remote teams" as the initial idea
    And I click "Save & Close"
    Then a new prompt should be created with the initial idea pre-populated
    And the prompt title should be AI-generated based on the user input
    And I should be redirected to the crafting board

  Scenario: Create a prompt and skip the repository URL
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I click "Skip"
    Then I should be on step 3
    And the prompt should not have a repository URL when saved

  Scenario: Attempt to save without an initial idea
    When I navigate to the new prompt page
    And I select "Feature Request"
    And I click "Skip"
    Then I should be on step 3
    When I click "Save & Continue" without entering an idea
    Then I should see an error message asking me to describe my initial idea
    And I should remain on step 3
    And no prompt should be created

  Scenario: Navigate back from step 3 to step 2
    When I navigate to the new prompt page
    And I select "Project"
    And I click "Skip"
    Then I should be on step 3
    When I click "Back"
    Then I should be on step 2
    And I should see a repository URL input field

  Scenario: Navigate back from step 2 to step 1
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I click "Back"
    Then I should be on step 1
    And I should see two workflow type options: "Feature Request" and "Project"

  Scenario: Attempt to create a prompt with an invalid repository URL
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I enter "not-a-valid-url" in the repository URL field
    And I click "Continue"
    Then I should see a validation error indicating the URL is invalid
    And I should remain on step 2
    And no prompt should be created
