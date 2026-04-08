Feature: Code Chat Workflow
  As a user, I want a free-form chat experience with AI that has full tool
  access, so I can get help with any coding task without a structured pipeline.

  Scenario: Create a new Code Chat session
    Given I am on the crafting board
    When I create a new "Code Chat" session with message "Help me refactor this module"
    Then I should see a chat session titled "New Chat"
    And the session should be in Phase 1 - Chat
    And the progress bar should not be visible

  Scenario: Send messages in the chat
    Given I have an active Code Chat session
    When I type a message and send it
    Then the AI should respond
    And I should be able to send another message

  Scenario: Mark chat session as done
    Given I have an active Code Chat session
    And the AI has responded to my messages
    When I click "Mark as Done"
    Then the session should be marked as complete
    And I should see the completion message "Chat session complete."

  Scenario: No phase transitions in Code Chat
    Given I have an active Code Chat session
    Then there should be no phase advance buttons
    And the session should stay in Phase 1 - Chat
