Feature: AI Session Debug Detail Page
  The AI Session Debug Detail page at /sessions/:workflow_session_id/ai/:ai_session_id
  shows the creation date and Claude session id in a header, then renders the
  full conversation history read from Destila.AI.History.get_messages/2. Every
  content block type emitted by ClaudeCode (text, thinking, tool usage, tool
  results, server tool usage, MCP tool usage, images, documents, redacted
  thinking, container uploads, compaction markers) renders without crashing the
  page, with an inspect/2 fallback for unknown block shapes.

  Scenario: Header shows creation date and Claude session id
    Given I open the AI Session Debug Detail page for a valid AI session
    Then the header should display the AI session creation date
    And the header should display the Claude session id

  Scenario: Back link navigates to the parent workflow runner
    Given I am on the AI Session Debug Detail page
    When I click the back link in the header
    Then I should be navigated to the parent workflow runner page

  Scenario: Unknown workflow session id redirects to the crafting board
    Given I request the AI Session Debug Detail page with an unknown workflow session id
    Then I should be redirected to the crafting board
    And I should see a "Session not found" flash

  Scenario: Unknown AI session id redirects to the workflow runner
    Given I request the AI Session Debug Detail page with an unknown AI session id
    Then I should be redirected to the workflow runner page

  Scenario: AI session belonging to another workflow is rejected
    Given I request the AI Session Debug Detail page with an AI session that belongs to a different workflow
    Then I should be redirected to the parent workflow runner page
    And I should see a flash explaining that the AI session does not belong to this workflow

  Scenario: Missing Claude session id shows empty state
    Given I open the AI Session Debug Detail page for an AI session without a Claude session id
    Then the page should render a "No conversation history available" empty state

  Scenario: Empty history shows empty state
    Given the history adapter returns an empty list
    When I open the AI Session Debug Detail page
    Then the page should render a "No conversation history available" empty state

  Scenario: History read failure shows empty state
    Given the history adapter returns an error tuple
    When I open the AI Session Debug Detail page
    Then the page should render an "Unable to read conversation history" empty state

  Scenario: Aliveness dot toggles live on the detail page
    Given I am on the AI Session Debug Detail page
    When the AlivenessTracker broadcasts an AI-specific aliveness change for this session
    Then the detail page aliveness dot should update without a reload

  Scenario: Text blocks render in order
    Given the history contains a user text block followed by an assistant text block
    When I open the AI Session Debug Detail page
    Then both blocks should be visible in order

  Scenario: Thinking block renders collapsed by default
    Given the history contains a thinking block
    When I open the AI Session Debug Detail page
    Then the thinking block should render as a collapsed details element

  Scenario: Redacted thinking block renders as a placeholder
    Given the history contains a redacted thinking block
    When I open the AI Session Debug Detail page
    Then the block should render a visible redacted placeholder

  Scenario: Tool use block renders tool name and pretty JSON input
    Given the history contains a tool use block
    When I open the AI Session Debug Detail page
    Then the block should display the tool name and pretty-printed JSON input

  Scenario: Tool result block is paired with its tool use
    Given the history contains a tool use block and a matching tool result block
    When I open the AI Session Debug Detail page
    Then the tool result block should reference the originating tool use id

  Scenario: Tool result with is_error renders with an error style
    Given the history contains a tool result block whose is_error flag is true
    When I open the AI Session Debug Detail page
    Then the block should render with an error style

  Scenario: Server tool use and result render with a server tool badge
    Given the history contains a server tool use block and a server tool result block
    When I open the AI Session Debug Detail page
    Then both blocks should render with a server tool label

  Scenario: MCP tool blocks render with server_name and tool name
    Given the history contains an MCP tool use block
    When I open the AI Session Debug Detail page
    Then the block should display its server_name and tool name

  Scenario: Image block with URL source renders an img element
    Given the history contains an image block with a URL source
    When I open the AI Session Debug Detail page
    Then the page should render an img element pointing at the URL

  Scenario: Image block with base64 source renders a placeholder
    Given the history contains an image block with a base64 source
    When I open the AI Session Debug Detail page
    Then the page should render a placeholder card without embedding the raw bytes

  Scenario: Compaction block renders a visible marker
    Given the history contains a compaction block
    When I open the AI Session Debug Detail page
    Then the page should render a compaction marker

  Scenario: Unknown block types render via an inspect fallback
    Given the history contains a content block whose struct is not recognized
    When I open the AI Session Debug Detail page
    Then the page should render the block through a pre element with inspect output
    And the page should not crash
