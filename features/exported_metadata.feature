Feature: Exported Metadata
  Workflow sessions store metadata during execution. Individual metadata entries
  can be flagged as "exported", making them available to other workflow sessions
  during their creation. A collapsible sidebar in the workflow runner displays
  the exported metadata for the current session during execution.

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

  # --- Inline Chat Messages ---

  Scenario: Markdown metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "markdown"
    Then a chat message should appear with the markdown card component
    And the card header should show the humanized metadata key
    And the card should have "Rendered" and "Markdown" tabs
    And the card should have a copy button

  Scenario: Non-markdown metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "text"
    Then a chat message should appear as a styled card
    And the card should show the humanized metadata key
    And the card should display the metadata value
    And the card should have a copy button
    But the card should not have view-mode tabs

  Scenario: Inline chat message appears in real-time
    Given I am on a session detail page
    And the session is actively processing
    When the AI exports new metadata
    Then the metadata chat message should appear in the conversation
    And the sidebar should also update with the new entry

  Scenario: Video metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "video_file"
    Then a chat message should appear with the video card component
    And the card header should show the humanized metadata key
    And the card should display a video player with click-to-play controls
    And the video should not autoplay

  Scenario: Video metadata sidebar entry has play button
    Given I am on a session detail page
    And the session has exported metadata of type "video_file"
    Then the sidebar entry should display a play button instead of a text preview
    When I click the play button
    Then a modal overlay should open with a larger video player

  Scenario: Markdown metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "markdown"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open with the rendered markdown

  Scenario: Text file metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "text_file"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open displaying the file's text content

  Scenario: Markdown file metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "markdown_file"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open with the rendered markdown from the file

  # --- User Prompt in Sidebar ---

  Scenario: User prompt appears at the top of the sidebar
    Given I am on a session detail page
    Then the sidebar should show a "User Prompt" section above the source code section
    And the section should display a view button

  Scenario: Open user prompt in markdown modal
    Given I am on a session detail page
    And the session has a user prompt
    When I click the view button on the user prompt section
    Then a full-screen modal overlay should appear with a dark backdrop
    And the modal should display the user prompt content with "Rendered" and "Markdown" tabs
    And the modal should default to the rendered HTML view

  # --- Source Code Terminal ---

  Scenario: Source code section shows open terminal button
    Given I am on a session detail page
    And the session has a worktree path
    Then the source code section should display an "Open Terminal" button

  Scenario: Open terminal button opens a Ghostty tab at the worktree path
    Given I am on a session detail page
    And the session has a worktree path
    When I click the "Open Terminal" button
    Then a new Ghostty terminal tab should open at the worktree path
