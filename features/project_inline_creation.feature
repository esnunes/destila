Feature: Project Inline Creation
  Users can create a new project inline from the workflow wizard phase.
  A project requires a name and at least one of a git repository URL or
  a local folder path. Optionally, a run command can be configured.

  Background:
    Given I am on the workflow wizard page

  Scenario: Create a project with a git repository URL
    When I click "Create New Project"
    Then I should see fields for project name, git repository URL, and local folder
    When I fill in the project name and a git repository URL
    And I click "Create & Select"
    Then the new project should be created and selected

  Scenario: Create a project with a local folder only
    When I click "Create New Project"
    When I fill in the project name and a local folder path
    And I click "Create & Select"
    Then the new project should be created and selected

  Scenario: Create a project with both git URL and local folder
    When I click "Create New Project"
    When I fill in the project name, a git repository URL, and a local folder path
    And I click "Create & Select"
    Then the new project should be created and selected

  Scenario: Cannot create a project without git URL or local folder
    When I click "Create New Project"
    When I fill in only the project name
    And I click "Create & Select"
    Then I should see an error indicating at least a git repository URL or local folder is required

  Scenario: Cannot create a project without a name
    When I click "Create New Project"
    When I fill in a git repository URL but leave the name empty
    And I click "Create & Select"
    Then I should see an error indicating a name is required
