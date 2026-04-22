Feature: Mise Auto-Trust
  A project may opt into automatic `mise trust -y` execution inside each
  new session worktree via the `mise_auto_trust` boolean flag (default
  false). When the flag is on, the worktree-preparation worker runs
  `mise trust -y` inside the newly created worktree before the existing
  setup command runs, so subsequent commands can rely on mise-managed
  tools. When the flag is off, no mise invocation occurs and worktree
  lifecycle is identical to before. Mise failures (missing binary,
  non-zero exit) are logged at warning level server-side and never block
  worktree readiness or the subsequent setup command.

  Scenario: Worktree preparation runs mise trust before the setup command
    Given a project with mise auto-trust enabled and a setup command
    When a new workflow session's worktree is ready
    Then `mise trust -y` is executed inside the worktree path
    And the setup command is sent to tmux afterwards

  Scenario: Worktree preparation runs mise trust even without a setup command
    Given a project with mise auto-trust enabled and no setup command
    When a new workflow session's worktree is ready
    Then `mise trust -y` is executed inside the worktree path
    And no setup command is sent to tmux

  Scenario: Worktree preparation skips mise trust when the flag is off
    Given a project with mise auto-trust disabled
    When a new workflow session's worktree is ready
    Then `mise trust -y` is not executed
    And the setup command is sent to tmux if present

  Scenario: A non-zero mise exit is logged and does not block setup
    Given a project with mise auto-trust enabled
    And `mise trust -y` exits with a non-zero status
    When the worker runs the post-worktree setup hook
    Then the non-zero exit is logged at warning level
    And the subsequent setup command still runs
    And the workflow session is still marked as worktree-ready

  Scenario: A missing mise binary is logged and does not block setup
    Given a project with mise auto-trust enabled
    And the `mise` binary is not installed on the host
    When the worker runs the post-worktree setup hook
    Then the raised error is logged at warning level
    And the subsequent setup command still runs
    And the workflow session is still marked as worktree-ready

  Scenario: The project card shows an auto-trust indicator when the flag is on
    Given a project with mise auto-trust enabled
    When I navigate to the projects page
    Then the project card shows an "auto-trust mise" indicator

  Scenario: The project card hides the auto-trust indicator when the flag is off
    Given a project with mise auto-trust disabled
    When I navigate to the projects page
    Then the project card does not show an "auto-trust mise" indicator
