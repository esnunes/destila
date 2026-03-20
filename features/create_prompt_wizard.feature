Feature: Create Prompt Wizard
  The Create Prompt wizard guides the user through a three-step flow:
  1. Choose a workflow type (Feature Request, Chore/Task, or Project)
  2. Optionally link a repository URL
  3. Describe the initial idea
  After completing the wizard, the user can save and continue to the chat,
  or save and close to return to their previous page.

  Background:
    Given I am logged in

  Scenario: Complete the wizard with Save & Continue
    When I navigate to the new prompt page
    Then I should see three step indicators
    And I should see three workflow type options: "Feature Request", "Chore / Task", and "Project"
    When I select one of the workflow types
    Then I should be on step 2
    And I should see a repository URL input field
    When I enter a valid repository URL
    And I click "Continue"
    Then I should be on step 3
    And I should see the initial idea question
    When I enter an initial idea
    And I click "Save & Continue"
    Then a new prompt should be created with the initial idea pre-populated
    And the prompt title should be AI-generated based on the user input
    And I should be redirected to the prompt detail page
    And the chat should show the initial idea as the first user message

  Scenario: Complete the wizard with Save & Close
    When I navigate to the new prompt page from the crafting board
    And I select one of the workflow types
    And I complete the repository URL step
    Then I should be on step 3
    When I enter an initial idea
    And I click "Save & Close"
    Then a new prompt should be created with the initial idea pre-populated
    And the prompt title should be AI-generated based on the user input
    And I should be redirected to the crafting board

  Scenario: Repository URL can only be skipped for Project type
    When I navigate to the new prompt page
    And I select a non-Project workflow type
    Then I should be on step 2
    And the "Skip" button should not be available
    When I click "Continue" without entering a URL
    Then I should see an error message indicating a repository URL is required
    And I should remain on step 2

  Scenario: Skip repository URL for Project type
    When I navigate to the new prompt page
    And I select "Project"
    Then I should be on step 2
    When I click "Skip"
    Then I should be on step 3
    And the prompt should not have a repository URL when saved

  Scenario: Attempt to save without an initial idea
    When I navigate to the new prompt page
    And I select one of the workflow types
    And I complete the repository URL step
    Then I should be on step 3
    When I click "Save & Continue" without entering an idea
    Then I should see an error message asking me to describe my initial idea
    And I should remain on step 3
    And no prompt should be created

  Scenario: Navigate back from step 3 to step 2
    When I navigate to the new prompt page
    And I select one of the workflow types
    And I complete the repository URL step
    Then I should be on step 3
    When I click "Back"
    Then I should be on step 2
    And I should see a repository URL input field

  Scenario: Navigate back from step 2 to step 1
    When I navigate to the new prompt page
    And I select one of the workflow types
    Then I should be on step 2
    When I click "Back"
    Then I should be on step 1
    And I should see three workflow type options: "Feature Request", "Chore / Task", and "Project"
