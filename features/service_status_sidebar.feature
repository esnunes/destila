Feature: Service Status Sidebar
  The workflow session sidebar displays a "Service" item for projects that are
  configured as webservices (i.e. projects with both a run command and a
  service env var name). The item reflects whether the project's development
  service is running or stopped, and becomes a clickable link to
  http://localhost:<port> in a new browser tab when running. The item is
  hidden entirely when the project is not a webservice or the session has no
  project.

  Scenario: Service item visible when project is a webservice
    Given I am on a session detail page
    And the session's project has a run_command and a service_env_var configured
    Then I should see a "Service" item in the sidebar

  Scenario: Service item hidden when project has no run_command
    Given I am on a session detail page
    And the session's project has no run_command configured
    Then no service item should appear in the sidebar

  Scenario: Service item hidden when project has no service_env_var
    Given I am on a session detail page
    And the session's project has no service_env_var configured
    Then no service item should appear in the sidebar

  Scenario: Service item hidden when session has no project
    Given I am on a session detail page
    And the session has no project assigned
    Then no service item should appear in the sidebar

  Scenario: Service icon is green when service is running
    Given I am on a session detail page
    And the session's service_state status is "running"
    Then the service icon should be green

  Scenario: Service icon is muted when service is stopped
    Given I am on a session detail page
    And the session's service_state status is "stopped"
    Then the service icon should be muted/gray

  Scenario: Running service with port is a clickable link
    Given I am on a session detail page
    And the session's service_state status is "running"
    And the session's service_state has a port assigned
    Then the service item should be a link to http://localhost:<port>
    And the link should open in a new browser tab

  Scenario: Stopped service is not clickable
    Given I am on a session detail page
    And the session's service_state status is "stopped"
    Then the service item should not be a clickable link

  Scenario: Nil service_state treated as stopped
    Given I am on a session detail page
    And the session's service_state is nil
    Then the service item should not be a clickable link
    And the service icon should be muted/gray

  Scenario: Service status updates in real-time
    Given I am on a session detail page
    And the session's service_state changes from stopped to running
    Then the service item should update to reflect the new state
    And the service link should become clickable with the correct port
