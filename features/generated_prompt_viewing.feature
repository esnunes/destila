Feature: Generated Prompt Viewing
  After the prompt crafting workflow is done, the generated implementation
  prompt is displayed in a styled card. Users can toggle between a rendered
  HTML view and a raw markdown view, and copy the markdown to their
  clipboard for use in external tools.

  Background:
    Given I am logged in
    And a prompt has been crafted

  Scenario: Default to rendered HTML view
    Then the prompt card should display the rendered HTML view
    And the card header should show "Rendered" as the active toggle
    And the card header should show a copy button

  Scenario: Toggle to markdown view
    When I click the "Markdown" toggle
    Then the prompt should be displayed as raw markdown in a monospace code block
    And the "Markdown" toggle should be active

  Scenario: Toggle back to rendered view
    Given I am viewing the markdown view
    When I click the "Rendered" toggle
    Then the prompt card should display the rendered HTML view
    And the "Rendered" toggle should be active

  Scenario: Copy markdown to clipboard
    When I click the copy button
    Then the raw markdown should be copied to the clipboard
    And the copy button should briefly show a confirmation icon

  Scenario: Copy works from either view
    Given I am viewing the rendered HTML view
    When I click the copy button
    Then the raw markdown should be copied to the clipboard
    When I toggle to the markdown view
    And I click the copy button
    Then the raw markdown should be copied to the clipboard
