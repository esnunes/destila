Feature: Project Archiving
  Users can archive projects to hide them from the projects page and session
  creation project selector. Archived projects are accessible from a dedicated
  archived projects page and can be restored. Archiving has no effect on linked
  sessions.

  # --- Archiving ---

  Scenario: Archive a project from the projects page
    Given I am on the projects page with an existing project
    When I click the archive button on the project
    And I confirm the archive action
    Then the project should be removed from the projects list
    And I should see a flash message "Project archived"

  Scenario: Cancel archive confirmation
    Given I am on the projects page with an existing project
    When I click the archive button on the project
    And I click "Cancel"
    Then the project should still be visible in the projects list
    And the archive confirmation should be dismissed

  # --- Unarchiving ---

  Scenario: Unarchive restores project to the active list
    Given I have archived a project titled "My Old Project"
    When I navigate to the archived projects page
    And I click the restore button on "My Old Project"
    Then the project should be removed from the archived list
    And I should see a flash message "Project restored"
    And the project should reappear on the projects page

  # --- Archived Projects Page ---

  Scenario: View archived projects on the archived page
    Given I have archived projects
    When I navigate to the archived projects page
    Then I should see the archived projects listed
    And each project should display its name, git URL, and local folder

  Scenario: Archived page is empty when no projects are archived
    Given no projects are archived
    When I navigate to the archived projects page
    Then I should see a message indicating there are no archived projects

  Scenario: Navigate to archived projects page
    Given I am on the projects page
    When I click the "Archived" link
    Then I should be navigated to the archived projects page

  # --- Interaction with Sessions ---

  Scenario: Archived project not shown in session creation project selector
    Given I have archived a project
    When I navigate to the session creation page
    Then the archived project should not appear in the project selector

  Scenario: Archiving a project does not affect its linked sessions
    Given I have a project with linked sessions
    When I archive the project
    Then the linked sessions should still appear on the crafting board
