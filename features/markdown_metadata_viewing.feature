Feature: Markdown Metadata Viewing
  When a workflow exports markdown-type metadata, it is displayed inline
  in the chat using the markdown card component. Users can toggle between
  a rendered HTML view and a raw markdown view, and copy the markdown to
  their clipboard for use in external tools. The card header shows the
  humanized metadata key name.

  Background:
    Given I am logged in
    And a session has exported markdown metadata

  Scenario: Default to rendered HTML view
    Then the markdown card should display the rendered HTML view
    And the card header should show the humanized metadata key
    And the card header should show a copy button

  Scenario: Toggle to markdown view
    When I click the "Markdown" toggle
    Then the metadata should be displayed as raw markdown in a monospace code block
    And the "Markdown" toggle should be active

  Scenario: Toggle back to rendered view
    Given I am viewing the markdown view
    When I click the "Rendered" toggle
    Then the markdown card should display the rendered HTML view
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
