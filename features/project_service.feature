Feature: Project-Level Services
  Project-level services run against a project's primary checkout on the
  default branch and are independent of any workflow session. They are a
  baseline-comparison and shared preview surface that stays up across
  session lifetimes.

  Owner: a project (singleton — at most one project-level service per project).
  Working directory: project.local_folder (or its effective folder for
  clone-only projects).
  Branch: the default branch auto-detected from git.
  Tmux: a dedicated session named "destila-service-project-<project_id>",
  window 0.
  Log path: tmp/services/project-<project_id>.log.
  PubSub topic: service:project-<project_id>.

  Three triggers funnel through ProjectServices.pull_and_restart/1:
    1. Oban Cron every 5 minutes (production only).
    2. Hooks on Workflows.archive_workflow_session/1 and
       SessionProcess.handle_mark_done/2.
    3. The "Pull latest & restart" button on the detail page.

  Pull strategy: fetch + fast-forward only. Dirty or diverged working trees
  fail loudly, surface an error, and do NOT restart.

  Self-hosted edge case: when project.local_folder canonicalizes to the BEAM's
  current working directory (i.e. the project IS the running Destila app), a
  restart delegates to an external supervisor via System.stop(0). On respawn,
  the boot resume hook reads persisted "starting"/"running" status and
  re-invokes start/1.

  Scenario: Singleton — start refuses when status is already "running"
    Given a project whose service_state["status"] is "running"
    When ProjectServices.start/1 is called for that project
    Then the call should return {:error, :already_running}

  Scenario: Singleton — start accepts "starting" entry state
    Given a project whose service_state["status"] is "starting"
    When ProjectServices.start/1 is called for that project
    Then the call should not be rejected by the "already running" guard

  Scenario: stop persists "stopped" status while preserving prior state fields
    Given a running project service on port 4321 with run_command and setup_command
    When ProjectServices.stop/1 is called
    Then service_state should have status "stopped"
    And service_state should still contain port, run_command, and setup_command

  Scenario: pull_and_restart no-ops when local is already up to date
    Given a project whose local checkout is up to date with origin
    When ProjectServices.pull_and_restart/1 is called
    Then last_pulled_at should be persisted
    And ServiceManager should NOT be asked to restart

  Scenario: pull_and_restart restarts when local is behind origin
    Given a project whose local checkout is behind origin
    When ProjectServices.pull_and_restart/1 is called
    Then a fast-forward should occur
    And ProjectServices.restart/1 should be invoked

  Scenario: pull_and_restart halts on a dirty working tree
    Given a project whose local checkout has uncommitted changes
    When ProjectServices.pull_and_restart/1 is called
    Then a {:project_service_error, :dirty, _} event should be broadcast
    And no fast-forward and no restart should occur

  Scenario: pull_and_restart halts on a diverged working tree
    Given a project whose local checkout has diverged from origin
    When ProjectServices.pull_and_restart/1 is called
    Then a {:project_service_error, :diverged, _} event should be broadcast
    And no fast-forward and no restart should occur

  Scenario: pull_and_restart halts when fetch fails
    Given a project whose remote is unreachable
    When ProjectServices.pull_and_restart/1 is called
    Then a {:project_service_error, :fetch, _} event should be broadcast
    And no fast-forward and no restart should occur

  Scenario: self_restart only fires when the project IS Destila itself
    Given a project whose local_folder canonicalizes to the BEAM's cwd
    When ProjectServices.self_restart/1 is called
    Then service_state["status"] should be persisted as "starting"
    And a status broadcast should be sent on the project topic
    And System.stop/1 should be called exactly once with code 0

  Scenario: self_restart raises on a non-self-hosted project
    Given a project whose local_folder does NOT match the BEAM's cwd
    When ProjectServices.self_restart/1 is called
    Then it should raise an ArgumentError
    And System.stop/1 should NOT be called

  Scenario: remove clears state and cleans up tmux + log
    Given a project with service_state set
    When ProjectServices.remove/1 is called
    Then service_state should become nil
    And the project's dedicated tmux session should be killed
    And the log file should be deleted

  Scenario: resume_all dispatches start/1 for "running" and "starting" projects
    Given two projects with service_state["status"] in ["running", "starting"]
    And one project with service_state["status"] = "stopped"
    When ProjectServices.resume_all/0 is called
    Then ProjectServices.start/1 should be called for the two non-stopped projects
    And ProjectServices.start/1 should NOT be called for the stopped project

  Scenario: archived projects are skipped by the polling worker
    Given an archived project whose service_state["status"] is "running"
    When ProjectServicePullRestartWorker.perform/1 is called with no args
    Then no pull_and_restart should be triggered for the archived project

  Scenario: ProjectServicePullRestartWorker dispatches a single project when given project_id
    Given a non-archived project with service_state["status"] = "running"
    When ProjectServicePullRestartWorker.perform/1 is called with %{"project_id" => id}
    Then ProjectServices.pull_and_restart/1 should be invoked for that project only

  Scenario: archive_workflow_session enqueues a pull-restart for the project
    Given a workflow session whose project has a project-level service
    When the session is archived
    Then a ProjectServicePullRestartWorker job should be enqueued with that project_id

  Scenario: archive_workflow_session does nothing when project_id is nil
    Given a workflow session with project_id nil
    When the session is archived
    Then no ProjectServicePullRestartWorker job should be enqueued

  Scenario: SessionProcess.mark_done enqueues a pull-restart for the project
    Given an active workflow session whose project has a project-level service
    When the session is marked done
    Then a ProjectServicePullRestartWorker job should be enqueued with that project_id
