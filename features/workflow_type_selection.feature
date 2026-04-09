Feature: Workflow Type Selection
  Users start a new workflow by selecting a type from the available options.
  The selection page shows all registered workflow types as cards with icons,
  labels, and descriptions. This is handled by CreateSessionLive.

  Scenario: View available workflow types
    When I navigate to the workflow selection page
    Then I should see the available workflow types
    And each type should have a label, description, and icon

  Scenario: Select a workflow type to start
    When I navigate to the workflow selection page
    And I click a workflow type
    Then I should be navigated to the creation form for that workflow type
