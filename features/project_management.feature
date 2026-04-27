Feature: Project Management
  Users can manage projects independently from sessions. A project has a name,
  an optional git repository URL, an optional local folder path, an optional
  setup command, an optional run command, an optional service env var name,
  an optional `domain` (publishing host for the project's webservice), an
  optional `basic_auth_enabled` boolean flag that defaults to off, and an
  optional `mise_auto_trust` boolean flag that defaults to off. At least one
  of git repository URL or local folder must be provided. When a project has
  both a run command and a service env var name it is treated as a webservice.
  When `domain` is set it is used as the Caddy publishing host for the
  project-level service; when `basic_auth_enabled` is true the published route
  is wrapped in HTTP basic auth. The same `domain` may be reused across
  projects (last successful register wins on the Caddy side). When
  `mise_auto_trust` is on, the worktree-preparation worker runs
  `mise trust -y` inside each new worktree before the setup command.
  Projects can be shared across multiple sessions.

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

  Scenario: Typing in git repository URL preserves focus after validation errors
    When I navigate to the projects page
    And I click "New Project"
    And I submit the form without filling in any fields
    Then I should see an error indicating a name is required
    When I type a git repository URL in the git repository URL field
    Then the git repository URL field should remain focused while I type

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

  Scenario: Create a project with run command and a service env var
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, a run command, and a service env var name
    And I click "Create"
    Then the project should be created
    And the project should be configured as a webservice

  Scenario: Create a project without a service env var name
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, and a run command and leave the service env var blank
    And I click "Create"
    Then the project should be created
    And the project should not be configured as a webservice

  Scenario: Edit a project's run configuration
    Given there is an existing project with a run command
    When I navigate to the projects page
    And I click edit on the project
    Then I should see the run command pre-filled
    When I update the run command
    And I click "Save"
    Then the project should be updated with the new run command

  Scenario: Service env var requires a valid environment variable name
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name and a git repository URL
    And I enter an invalid service env var name
    And I click "Create"
    Then I should see a validation error for the service env var

  Scenario: Create a project with a setup command
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, a setup command, and a run command
    And I click "Create"
    Then the project should be created
    And I should see both the setup command and the run command displayed in the project card

  Scenario: Edit a project's setup command
    Given there is an existing project with a setup command
    When I navigate to the projects page
    And I click edit on the project
    Then I should see the setup command pre-filled
    When I update the setup command
    And I click "Save"
    Then the project should be updated with the new setup command

  Scenario: Create a project with mise auto-trust enabled
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name and a git repository URL
    And I check the "Auto-trust mise" checkbox
    And I click "Create"
    Then the project should be created with mise_auto_trust set to true

  Scenario: Create a project without touching mise auto-trust
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name and a git repository URL
    And I leave the "Auto-trust mise" checkbox unchecked
    And I click "Create"
    Then the project should be created with mise_auto_trust set to false

  Scenario: Edit a project to toggle mise auto-trust
    Given there is an existing project with mise auto-trust disabled
    When I navigate to the projects page
    And I click edit on the project
    And I check the "Auto-trust mise" checkbox
    And I click "Save"
    Then the project should be updated with mise_auto_trust set to true

  Scenario: Create a project with a publishing domain
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, a run command, a service env var, and a domain "myapp.example.com"
    And I click "Create"
    Then the project should be created with domain "myapp.example.com"

  Scenario: Domain is optional on project creation
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, a run command, and a service env var, and leave the domain blank
    And I click "Create"
    Then the project should be created with no domain

  Scenario: Two projects may share the same domain
    Given there is an existing project with domain "shared.example.com"
    When I navigate to the projects page
    And I click "New Project"
    When I fill in the name, a git repository URL, a run command, a service env var, and the domain "shared.example.com"
    And I click "Create"
    Then the project should be created with domain "shared.example.com"

  Scenario: Edit a project to toggle basic auth
    Given there is an existing project with `basic_auth_enabled` false
    When I navigate to the projects page
    And I click edit on the project
    And I check the "Require basic auth" checkbox
    And I click "Save"
    Then the project should be updated with `basic_auth_enabled` set to true
