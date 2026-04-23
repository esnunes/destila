Feature: Code Redesign Analysis Workflow
  The "Code Redesign Analysis" workflow analyzes an existing codebase within a
  user-supplied scope and produces a redesign proposal plus an agent-ready
  implementation prompt.

  Session creation and setup are handled by CreateSessionLive before the
  session reaches WorkflowRunnerLive. The workflow progresses through four phases:
  1. Extract Requirements - AI analyzes the codebase and exports `requirements_doc` (non-interactive)
  2. Greenfield Design - AI proposes a from-scratch design and exports `greenfield_design` (non-interactive)
  3. Compare & Improve - AI compares both and exports `comparison_report` + `prompt_generated` (non-interactive)
  4. Adjustments - User requests refinements and re-exports affected keys (interactive)

  Scenario: Workflow type selection shows the new workflow
    When I navigate to create a new workflow
    Then I should see "Code Redesign Analysis" as a workflow option
    And I should see the description "Analyze an area of a codebase and propose a redesign with an implementation prompt"

  Scenario: Creation form collects scope and project
    When I navigate to start a new "Code Redesign Analysis" workflow
    Then I should see a form to select a project and describe my scope
    When I select a project and enter my scope
    And I click "Start"
    Then a workflow session should be created with setup status
    And I should be redirected to the session detail page

  Scenario: Creation form requires a scope
    When I navigate to start a new "Code Redesign Analysis" workflow
    And I select a project but leave the scope empty
    And I click "Start"
    Then I should see an error indicating a scope is required

  Scenario: Creation form requires a project
    When I navigate to start a new "Code Redesign Analysis" workflow
    And I enter a scope but do not select a project
    And I click "Start"
    Then I should see an error indicating a project is required

  Scenario: Phase 1 - Non-interactive AI extracts requirements
    Given I am on phase 1 of a code redesign analysis workflow
    Then I should not see a text input
    And I should see the AI working autonomously

  Scenario: Non-interactive phase shows retry on error
    Given a non-interactive phase encountered an error
    Then I should see a "Retry" button

  Scenario: Exported metadata sidebar shows all four artifacts
    Given the workflow has exported all four artifacts
    When I view the session detail page
    Then the sidebar should display entries for "Requirements Doc", "Greenfield Design", "Comparison Report", and "Prompt Generated"

  Scenario: Phase 4 - Adjustments phase is interactive
    Given the non-interactive phases are complete
    When I reach the adjustments phase
    Then I should see a text input to request changes

  Scenario: Phase 4 re-export replaces the original artifact
    Given the workflow has exported `requirements_doc` during phase 1
    When phase 4 re-exports `requirements_doc` with revised content
    Then there should be exactly one exported row for that key
    And the stored value should be the revised content

  Scenario: Prompt Generated surfaces in the Implement a Prompt source picker
    Given a completed code redesign analysis session with exported `prompt_generated`
    When I navigate to start a new "Implement a Prompt" workflow
    Then I should see the completed session in the prompt source list

  Scenario: Crafting board shows the redesign analysis workflow
    Given I have an active code redesign analysis workflow
    When I visit the crafting board
    Then I should see the workflow card with the "Redesign Analysis" badge
