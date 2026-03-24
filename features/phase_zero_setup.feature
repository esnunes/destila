Feature: Phase 0 - Project Setup
  After completing the session creation wizard, the chat page shows a
  "Phase 0 — Setup" section that prepares the project environment before
  the conversation begins. Setup runs in the background and the user can
  navigate away without interrupting it.

  Background:
    Given I am logged in

  Scenario: Setup for a session with a local project
    Given I have a project with a local folder that is a git repository
    When I complete the session wizard linked to that project
    Then I should be redirected to the session detail page
    And I should see a "Phase 0 — Setup" section
    And I should see the step "Generating title..."
    When the title is generated
    Then I should see the generated title
    And I should see the step "Pulling latest changes..."
    When the pull completes
    Then I should see "Repository up to date"
    And I should see the step "Creating worktree..."
    When the worktree is created
    Then I should see "Worktree ready"
    And I should see the step "Starting AI session..."
    When the AI session starts
    Then I should see "AI session ready"
    And Phase 0 should auto-collapse
    And Phase 1 should begin automatically

  Scenario: Setup for a session with a remote-only project
    Given I have a project with only a git repo URL and no local folder
    When I complete the session wizard linked to that project
    Then I should be redirected to the session detail page
    And I should see a "Phase 0 — Setup" section
    And I should see the step "Generating title..."
    And I should see the step "Cloning repository..."
    When the clone completes
    Then I should see "Repository cloned"
    And the repository should be stored in the local cache folder
    And I should see the step "Creating worktree..."
    When the worktree is created
    Then the worktree should be at "<cache-folder>/.claude/worktrees/<session-id>"
    And setup should continue through to AI session start

  Scenario: Setup for a session without a linked project
    Given I completed the wizard without linking a project
    When I am redirected to the session detail page
    Then I should see a "Phase 0 — Setup" section
    And I should only see the step "Generating title..."
    When the title is generated
    Then Phase 0 should auto-collapse
    And Phase 1 should begin automatically
    And the AI session should start without a working directory

  Scenario: A setup step fails
    Given I have a project with a local folder
    And the git pull fails due to a network error
    When I am on the session detail page during setup
    Then I should see the error message for the failed step
    And I should see a "Retry" button
    When I click "Retry"
    Then the failed step should be attempted again

  Scenario: User navigates away during setup
    Given setup is in progress for my session
    When I navigate to another page
    Then the setup should continue running in the background
    When I return to the session detail page
    Then I should see the current setup progress

  Scenario: Chat input disabled during setup
    Given setup is in progress for my session
    When I am on the session detail page
    Then the chat input should be disabled
    When setup completes
    Then the chat input should be enabled
