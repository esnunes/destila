Feature: Workflow Session Sidebar
  The workflow runner displays a collapsible right sidebar showing exported
  metadata, session details, project info, and AI sessions for the active
  workflow session.

  Background:
    Given I am logged in

  Scenario: Sidebar is visible by default on an active session
    Given I am on a session detail page
    Then I should see the session sidebar on the right
    And the phase content should share horizontal space with the sidebar

  Scenario: Sidebar is not shown on workflow type selection
    When I navigate to create a new workflow
    Then I should not see the session sidebar

  Scenario: Collapse and expand the sidebar
    Given I am on a session detail page
    And the sidebar is open
    When I click the sidebar toggle button
    Then the sidebar should collapse
    And the phase content should expand to full width
    When I click the sidebar toggle button again
    Then the sidebar should reopen

  Scenario: Sidebar shows session info
    Given I am on a session detail page
    Then the sidebar should show the session creation date
    And the sidebar should show the session last updated date
    And the sidebar should show the session duration

  Scenario: Sidebar shows done status for completed session
    Given the session is marked as done
    Then the sidebar should show the completion date

  Scenario: Sidebar shows project info
    Given I am on a session with a linked project
    Then the sidebar should show the project name
    And the sidebar should show the repository URL

  Scenario: Sidebar shows exported metadata grouped by phase
    Given the session has metadata exported from multiple phases
    Then the sidebar should show metadata grouped under phase name headings
    And each group should display its key-value pairs

  Scenario: Sidebar updates when new metadata is exported
    Given the sidebar is open
    When a phase exports new metadata
    Then the sidebar should update to show the new metadata entry

  Scenario: Sidebar shows AI sessions
    Given the session has associated AI conversation sessions
    Then the sidebar should list the AI sessions
    And each AI session should show its status
