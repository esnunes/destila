Feature: AI Sessions Sidebar
  The workflow runner right sidebar exposes an "AI Sessions" section between the
  "Workflow Session" and "Exported Metadata" sections. Each row represents a past
  or current AI session for the workflow, shows a live aliveness dot (green when
  the Claude Code GenServer is running, muted when not), and navigates to the
  AI Session Debug Detail page when clicked.

  Scenario: AI Sessions section renders between Workflow Session and Exported Metadata
    Given I am on a workflow runner page
    Then the right sidebar should contain an "AI Sessions" section
    And the section should sit between the "Workflow Session" and "Exported Metadata" sections

  Scenario: AI Sessions section lists every AI session for the workflow
    Given the workflow session has two AI sessions
    When I open the workflow runner page
    Then the sidebar should show two AI session rows
    And each row should be a link to the AI Session Debug Detail page
    And the rows should be ordered from oldest to newest

  Scenario: AI session row displays the creation time in the browser timezone
    Given the workflow session has one AI session
    When I open the workflow runner page
    Then the row should render the session timestamp in the browser's local timezone

  Scenario: Empty state when no AI sessions exist
    Given the workflow session has no AI sessions
    When I open the workflow runner page
    Then the sidebar should indicate "No AI sessions yet"

  Scenario: Running AI session shows a green aliveness dot
    Given the workflow session has one AI session whose Claude Code process is alive
    When I open the workflow runner page
    Then the corresponding sidebar row should display a green aliveness dot

  Scenario: Inactive AI session shows a muted aliveness dot
    Given the workflow session has one AI session with no running Claude Code process
    When I open the workflow runner page
    Then the corresponding sidebar row should display a muted aliveness dot

  Scenario: Aliveness dot toggles to green in real time when a session starts
    Given I am on a workflow runner page showing an inactive AI session
    When the AlivenessTracker broadcasts that the AI session is alive
    Then the corresponding row should update to a green aliveness dot without a reload

  Scenario: Aliveness dot toggles to muted in real time when a session stops
    Given I am on a workflow runner page showing a running AI session
    When the AlivenessTracker broadcasts that the AI session is no longer alive
    Then the corresponding row should update to a muted aliveness dot without a reload

  Scenario: Clicking a row opens the AI Session Debug Detail page
    Given I am on a workflow runner page
    And the workflow session has one AI session
    When I click the AI session row
    Then I should be navigated to the AI Session Debug Detail page for that session

  Scenario: Workflow header aliveness dot is unaffected
    Given I am on a workflow runner page
    When the AlivenessTracker broadcasts an AI-specific aliveness change
    Then the workflow-level header aliveness dot should remain unchanged
