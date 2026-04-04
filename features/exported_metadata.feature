Feature: Exported Metadata
  Workflow sessions store metadata during execution. Individual metadata entries
  can be flagged as "exported", making them available to other workflow sessions
  during their creation. A collapsible sidebar in the workflow runner displays
  the exported metadata for the current session during execution.

  Background:
    Given I am logged in

  Scenario: Metadata is private by default
    Given a workflow session has metadata entries
    Then metadata entries should not be exported by default

  Scenario: Generated prompt is marked as exported
    Given a "Brainstorm Idea" workflow completes Phase 6 - Prompt Generation
    Then the generated prompt metadata should be marked as exported

  Scenario: Only exported metadata is returned when querying for external use
    Given a workflow session has both exported and non-exported metadata
    When another workflow session queries the metadata
    Then only exported entries should be returned

  Scenario: Sidebar displays exported metadata during workflow execution
    Given I am on a session detail page
    And the session has exported metadata entries
    Then I should see a sidebar showing the exported metadata
    And each entry should display its phase name and key

  Scenario: Sidebar is empty when no metadata is exported
    Given I am on a session detail page
    And the session has no exported metadata entries
    Then the sidebar should indicate no exported metadata is available

  Scenario: Sidebar updates in real-time as metadata is exported
    Given I am on a session detail page
    And the session is actively processing
    When a phase marks new metadata as exported
    Then the sidebar should update to show the new entry

  Scenario: Sidebar is open by default
    Given I am on a session detail page for the first time
    Then the sidebar should be open

  Scenario: Collapse and expand sidebar
    Given I am on a session detail page
    And the sidebar is open
    When I collapse the sidebar
    Then the sidebar should be hidden
    When I expand the sidebar
    Then the sidebar should be visible again

  Scenario: Sidebar collapse state persists across page loads
    Given I am on a session detail page
    And I collapse the sidebar
    When I navigate away and return to the session detail page
    Then the sidebar should still be collapsed
