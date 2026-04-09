Feature: Markdown Metadata Viewing
  When a workflow exports markdown-type metadata, it is displayed inline
  in the chat using the markdown card component and can be opened in a
  full-screen modal from the metadata sidebar. Users can toggle between
  a rendered HTML view and a raw markdown view, and copy the markdown to
  their clipboard. The card header shows the humanized metadata key name.

  Background:
    Given a session has exported markdown metadata

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

  Scenario: Open markdown in modal from sidebar
    When I click the view button on the sidebar markdown entry
    Then a full-screen modal overlay should appear with a dark backdrop
    And the modal should display the markdown with "Rendered" and "Markdown" tabs
    And the modal should default to the rendered HTML view
    And the modal should have a copy button

  Scenario: Toggle views in markdown modal
    Given the markdown modal is open
    When I click the "Markdown" tab in the modal
    Then the modal should display raw markdown in a monospace code block
    When I click the "Rendered" tab in the modal
    Then the modal should display the rendered HTML view

  Scenario: Copy markdown from modal
    Given the markdown modal is open
    When I click the copy button in the modal
    Then the raw markdown should be copied to the clipboard
    And the copy button should briefly show a confirmation icon

  Scenario: Close markdown modal
    Given the markdown modal is open
    When I close the modal
    Then the modal should disappear
    And the inline markdown card in the chat should still be visible
