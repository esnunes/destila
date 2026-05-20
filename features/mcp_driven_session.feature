Feature: MCP-driven agent session
  Destila operates as an MCP server. The agent (Claude Code CLI) talks to
  Destila through MCP tool calls only — never through assistant text.
  Sessions support two host modes: embedded (Destila launches `claude` in
  its own PTY) and external (the user runs `claude` themselves).

  # --- Session creation and layout ---

  Scenario: Session is created without a chat textarea
    Given I create a new MCP-driven session from the crafting board
    Then I should land on the session page without any chat textarea
    And the page should show an empty exports placeholder, not a chat transcript

  Scenario: Crafting board exposes the new entry point alongside the old one
    Given I open the crafting board
    Then I should see a card for creating a new MCP-driven session
    And the existing chat-path entry should still be present

  Scenario: Empty session shows an exports placeholder, not a chat transcript
    Given I open an MCP-driven session with no exports yet
    Then the exports panel should render an empty-state placeholder

  Scenario: Session detail page is reachable while the agent is disconnected
    Given an MCP-driven session has no connected agent
    When I navigate to the session detail page
    Then the page should mount normally with a "not connected" indicator

  # --- Explicit-only phase transitions ---

  Scenario: phase_complete auto-advances the session
    Given an active MCP-driven session
    When the agent calls mcp__destila__session with action=phase_complete
    Then the current phase index should advance
    And no confirmation prompt should appear

  Scenario: suggest_phase_complete waits for user confirmation
    Given an active MCP-driven session
    When the agent calls mcp__destila__session with action=suggest_phase_complete
    Then a confirmation prompt should appear in the UI with the agent's reason
    And the phase index should not change until the user confirms

  Scenario: Phase advances only on an explicit phase_complete tool call
    Given an active MCP-driven session
    When the agent emits assistant text suggesting the phase is done
    Then the phase index should not change

  # --- Exports ---

  Scenario: New exports appear in real-time at the top of the session view
    Given I am on an active MCP-driven session page
    When the agent calls mcp__destila__session with action=export
    Then the new export should appear in the exports panel without a navigation

  Scenario: Exports from prior phases remain available across handoff
    Given an MCP-driven session has exports from a completed phase
    When the next phase's agent starts
    Then the new agent should be able to read them via the MCP exports tool

  # --- ask_user_question semantics ---

  Scenario: ask_user_question tool call does not block on the user's reply
    Given an active MCP-driven session
    When the agent calls mcp__destila__ask_user_question
    Then the tool call returns immediately with a question id
    And the question appears in the UI

  Scenario: Selection is written to the agent's stdin in embedded host mode
    Given an embedded-host session with a pending question
    When the user clicks an option in the UI
    Then Destila writes the selected value to the agent's stdin

  Scenario: Selection is surfaced for manual paste in external host mode
    Given an external-host session with a pending question
    When the user clicks an option in the UI
    Then the selected value should appear in a paste-target panel

  # --- Embedded host mode ---

  Scenario: Destila pushes a phase-kickoff prompt to the agent's stdin
    Given an embedded-host session is starting a new phase
    Then Destila writes the phase's kickoff prompt to the agent's stdin

  Scenario: Phase boundary stops the current agent and starts a fresh one
    Given an embedded-host session
    When a phase_complete tool call is received
    Then Destila terminates the current claude process
    And spawns a new one for the next phase

  Scenario: User types directly into the embedded terminal
    Given I am on an embedded-host session page
    When I type into the embedded terminal
    Then the bytes are forwarded to the agent's stdin

  Scenario: Agent exit without phase_complete leaves the phase open
    Given an embedded-host session is running
    When the agent process exits before calling phase_complete
    Then the session status should be disconnected
    And the current phase index should not change

  # --- External host mode ---

  Scenario: Creating an external-host session shows MCP connection instructions
    Given I create a new external-host MCP-driven session
    Then I should see the bridge install command, token, and URL

  Scenario: Session activates when the external agent connects
    Given an external-host session is awaiting an agent
    When the external agent connects via the SSE channel
    Then the session status should become active

  Scenario: Destila does not attempt stdin pushes in external host mode
    Given an external-host session is active
    When a kickoff prompt is queued
    Then Destila must not invoke any PTY write

  Scenario: External host handoff requires user action
    Given an external-host session completes a phase
    Then a restart-your-agent modal should be shown to the user

  # --- Event log ---

  Scenario: Session log records only tool-call events
    Given an active MCP-driven session
    Then the event log table should contain only tool-call events
    And no agent assistant text should be stored

  # --- Service tool parity ---

  Scenario: Service tool calls are dispatched to ServiceManager
    Given an MCP-driven session attached to a project with a configured service
    When the agent calls mcp__destila__service with action=status
    Then ServiceManager.execute is invoked with the project's service config
