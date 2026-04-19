Feature: Dashboard
  The landing page at / welcomes the user with an informational banner
  listing any required external CLI tools missing from their PATH
  (claude, tmux, ffmpeg, agent-browser) and a grid of call-to-action
  cards pointing at the main features (Crafting Board, Drafts, New
  Workflow, Projects). The banner is purely informational — it cannot
  be dismissed and it never disables any feature. A "Recheck" button
  re-runs the detection.

  # --- Missing-tools banner ---

  Scenario: Banner is hidden when all required tools are available
    Given every required tool is on my PATH
    When I open the dashboard
    Then I should not see the missing-tools banner

  Scenario: Banner lists each missing tool with an install hint
    Given ffmpeg and agent-browser are not on my PATH
    When I open the dashboard
    Then I should see the missing-tools banner
    And it should list ffmpeg and agent-browser
    And each missing tool row should show an install command with a copy affordance and a docs link

  Scenario: Banner is informational and does not disable any feature
    Given claude is not on my PATH
    When I open the dashboard
    Then I should see the missing-tools banner
    And every feature call-to-action should remain enabled

  Scenario: Banner cannot be dismissed
    Given tmux is not on my PATH
    When I open the dashboard
    Then the banner should have no dismiss or close control

  Scenario: Recheck refreshes the banner after I install a tool
    Given ffmpeg is missing when the dashboard mounts
    When I install ffmpeg and click Recheck
    Then the banner should no longer be visible

  Scenario: Recheck still shows tools that remain missing
    Given ffmpeg and agent-browser are missing
    When I click Recheck without installing anything
    Then both tools should still be listed in the banner

  # --- Feature overview ---

  Scenario: Dashboard shows call-to-action cards for the main features
    Given I am on the dashboard
    When the page renders
    Then I should see CTA cards for Crafting Board, Drafts, New Workflow, and Projects
    And each card should carry a short description

  Scenario: Crafting Board CTA navigates to the crafting board
    Given I am on the dashboard
    When I click the Crafting Board card
    Then I should be taken to /crafting

  Scenario: Drafts CTA navigates to the drafts board
    Given I am on the dashboard
    When I click the Drafts card
    Then I should be taken to /drafts

  Scenario: New Workflow CTA navigates to workflow creation
    Given I am on the dashboard
    When I click the New Workflow card
    Then I should be taken to /workflows

  Scenario: Projects CTA navigates to the projects page
    Given I am on the dashboard
    When I click the Projects card
    Then I should be taken to /projects

  Scenario: Dashboard does not show live activity, stats, or a hero block
    Given I am on the dashboard
    When the page renders
    Then I should not see the old crafting summary, live counts, or recent-activity lists
