Feature: Service Status Sidebar
  The workflow session sidebar displays a "Service" item that reflects whether
  the project's development service is running or stopped, with conditional
  link behavior that opens the service in a new browser tab when running.

  Scenario: Service item visible when project has run_command
    Given I am on a session detail page
    And the session's project has a run_command configured
    Then I should see a "Service" item in the sidebar

  Scenario: Service item disabled when no run_command configured
    Given I am on a session detail page
    And the session's project has no run_command configured
    Then I should see a disabled "Service" item in the sidebar
    And the item should indicate the feature is not set up

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
    And the project has port_definitions and ports are assigned
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
