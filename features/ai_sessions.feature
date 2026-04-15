Feature: AI Sessions sidebar and detail page

  Scenario: AI sessions list appears in the right sidebar
    Given a workflow session with two AI sessions
    When I view the workflow runner page
    Then I see the AI sessions section in the sidebar
    And each AI session item links to its detail page

  Scenario: AI sessions sidebar shows empty state when no sessions exist
    Given a workflow session with no AI sessions
    When I view the workflow runner page
    Then I see the AI sessions section with an empty state message

  Scenario: AI sessions sidebar updates in real time when a new session is created
    Given I am viewing the workflow runner page
    When a new AI session is created for the current workflow session
    Then the sidebar list updates to include the new AI session item

  Scenario: AI session detail page shows session metadata and messages
    Given a workflow session with an AI session that has messages
    When I navigate to the AI session detail page
    Then I see the AI session creation timestamp
    And I see the Claude session ID
    And I see all messages in chronological order

  Scenario: AI session detail page has a back button to the workflow session
    Given a workflow session with an AI session
    When I navigate to the AI session detail page
    Then I see a back link that navigates to the workflow session page
