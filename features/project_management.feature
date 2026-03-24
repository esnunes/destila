Feature: Project Management
  Users can manage projects independently from sessions. A project has a name,
  an optional git repository URL, and an optional local folder path. At least
  one of git repository URL or local folder must be provided. Projects can be
  shared across multiple sessions.

  Background:
    Given I am logged in

  Scenario: View list of projects
    Given there are existing projects
    When I navigate to the projects page
    Then I should see a list of all projects
    And each project should display its name, git repository URL, and local folder

  Scenario: Create a new project with git repository URL
    When I navigate to the projects page
    And I click "New Project"
    Then I should see a form with fields for name, git repository URL, and local folder
    When I fill in the name and a git repository URL
    And I click "Create"
    Then the project should be created
    And I should see it in the projects list

  Scenario: Create a new project with local folder only
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name and a local folder path
    And I click "Create"
    Then the project should be created

  Scenario: Create a new project with both git URL and local folder
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, and a local folder path
    And I click "Create"
    Then the project should be created

  Scenario: Cannot create a project without git URL or local folder
    When I navigate to the projects page
    And I click "New Project"
    When I fill in only the name
    And I click "Create"
    Then I should see an error indicating at least a git repository URL or local folder is required

  Scenario: Cannot create a project without a name
    When I navigate to the projects page
    And I click "New Project"
    When I fill in a git repository URL but leave the name empty
    And I click "Create"
    Then I should see an error indicating a name is required

  Scenario: Edit an existing project
    Given there is an existing project
    When I navigate to the projects page
    And I click edit on the project
    Then I should see the project form pre-filled with the current values
    When I update the project name
    And I click "Save"
    Then the project should be updated

  Scenario: Cannot save an edited project with invalid data
    Given there is an existing project
    When I navigate to the projects page
    And I click edit on the project
    When I clear all fields and click "Save"
    Then I should see validation errors for name and location

  Scenario: Delete a project not linked to any sessions
    Given there is a project with no linked sessions
    When I navigate to the projects page
    And I click delete on the project
    And I confirm the deletion
    Then the project should be removed from the list

  Scenario: Cannot delete a project linked to sessions
    Given there is a project linked to one or more sessions
    When I navigate to the projects page
    And I click delete on the project
    Then I should see a message indicating the project cannot be deleted while linked to sessions
