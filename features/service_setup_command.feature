Feature: Service Setup Command
  A project may declare an optional setup command that runs inside the tmux
  service window (index 9) in two situations: once automatically right after
  the session's worktree is created (without any port allocated or env var
  exported), and again before every run command on service start or restart
  (with the project's service env var exported for both setup and run). Setup
  and run are delivered in a single send_keys call chained with ";" so a
  non-zero exit from setup still lets the run command proceed. Setup output
  stays inside the tmux window and is not surfaced in the web UI.

  Scenario: Worktree creation triggers setup command in the tmux service window
    Given a project with a setup command
    When a new workflow session's worktree is ready
    Then the setup command is sent to window 9 of the session's tmux session
    And the web UI is not notified of setup completion

  Scenario: A project without a setup command keeps its current behavior
    Given a project without a setup command
    When a new workflow session's worktree is ready
    Then no setup invocation is made to tmux
    And the run command on service start behaves exactly as before

  Scenario: Setup and run are chained with ; so setup failure does not block run
    Given a project with a setup command and a run command
    When the service is started
    Then the composed shell string chains setup and run with ";"
    And the run command executes even if setup exits non-zero

  Scenario: Post-worktree setup runs without allocating a port
    Given a project with a setup command and a service env var
    When a new workflow session's worktree is ready
    Then the setup command is sent to tmux without any env export
    And no port is reserved for the setup invocation

  Scenario: Start/restart allocates a port and exports the service env var for both setup and run
    Given a project with a setup command, a run command, and a service env var
    When the service is started
    Then a single ephemeral port is reserved
    And the service env var is exported with that port before both setup and run

  Scenario: Empty setup_command behaves like nil
    Given a project whose setup command is an empty string
    When a new workflow session's worktree is ready
    Then no setup invocation is made to tmux
    And the service start command contains no ";" separator

  Scenario: Setup failures do not block worktree readiness
    Given a project with a setup command
    And the tmux send_keys call fails
    When the worker runs the post-worktree setup hook
    Then the failure is logged
    And the workflow session is still marked as worktree-ready
