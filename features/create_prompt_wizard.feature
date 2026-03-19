Feature: Create Prompt Wizard
  The Create Prompt wizard guides the user through a two-step flow:
  1. Choose a workflow type (Feature Request or Project)
  2. Optionally link a repository URL
  After completing the wizard, a new prompt is created and the user
  is redirected to its detail page.

  Background:
    Given I am logged in

  Scenario: Create a Feature Request prompt with a repository URL
    When I navigate to the new prompt page
    Then I should see two workflow type options: "Feature Request" and "Project"
    When I select "Feature Request"
    Then I should be on step 2
    And I should see a repository URL input field
    When I enter "https://github.com/owner/repo" in the repository URL field
    And I click "Continue"
    Then a new prompt should be created
    And I should be redirected to the prompt detail page

  Scenario: Create a Project prompt with a repository URL
    When I navigate to the new prompt page
    And I select "Project"
    Then I should be on step 2
    And I should see a repository URL input field
    When I enter "https://github.com/owner/repo" in the repository URL field
    And I click "Continue"
    Then a new prompt should be created
    And I should be redirected to the prompt detail page

  Scenario: Create a prompt and skip the repository URL
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I click "Skip"
    Then a new prompt should be created without a repository URL
    And I should be redirected to the prompt detail page

  Scenario: Attempt to create a prompt with an invalid repository URL
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I enter "not-a-valid-url" in the repository URL field
    And I click "Continue"
    Then I should see a validation error indicating the URL is invalid
    And I should remain on step 2
    And no prompt should be created

  Scenario: Navigate back from step 2 to step 1
    When I navigate to the new prompt page
    And I select "Feature Request"
    Then I should be on step 2
    When I click "Back"
    Then I should be on step 1
    And I should see two workflow type options: "Feature Request" and "Project"
