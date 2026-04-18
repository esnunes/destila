Feature: Drafts Board
  Users capture loose ideas as drafts on a priority-based kanban board at
  /drafts. Each draft carries a prompt, a project, and a priority (High,
  Medium, or Low). Drafts can be edited, reordered within a column, moved
  across priority columns via drag-and-drop, discarded (soft-archived with
  no restore path), or launched directly into a workflow — bypassing the
  prompt + project selection step. Launching a workflow from a draft
  archives the draft only after the workflow session is successfully
  created.

  # --- Board ---

  Scenario: View drafts grouped by priority columns
    Given I have drafts across all three priorities
    When I navigate to the drafts board
    Then I should see three columns labeled "High", "Medium", and "Low"
    And each draft should appear in the column matching its priority

  Scenario: Draft card shows the prompt
    Given I have a draft with prompt "Refactor session archiving"
    When I navigate to the drafts board
    Then the draft card should display the prompt text

  Scenario: Empty board shows guidance to create the first draft
    Given I have no drafts
    When I navigate to the drafts board
    Then I should see an empty state inviting me to create the first draft

  # --- Sidebar ---

  Scenario: Sidebar has a Drafts entry next to Crafting Board
    Given I am on any page with the sidebar visible
    When I look at the navigation sidebar
    Then I should see a "Drafts" entry peer to "Crafting Board"
    And clicking it should navigate to the drafts board

  # --- Create ---

  Scenario: Create a new draft from the drafts board
    Given I am on the drafts board
    When I click "New Draft"
    And I fill in the prompt, pick a project, and pick a priority
    And I save the draft
    Then the draft should appear in the matching priority column

  Scenario: Cannot create a draft without a project
    Given I am on the new draft page
    When I submit the form without selecting a project
    Then I should see a validation error about the project

  Scenario: Cannot create a draft without a priority
    Given I am on the new draft page
    When I submit the form without picking a priority
    Then I should see a validation error about the priority

  # --- Detail / Edit ---

  Scenario: Open a draft detail page
    Given I have an existing draft
    When I click the draft card on the board
    Then I should be taken to the draft's detail page
    And the form should be pre-populated with the draft's prompt, project, and priority

  Scenario: Edit the prompt, project, and priority of an existing draft
    Given I am on an existing draft's detail page
    When I change the prompt, project, and priority and save
    Then the changes should persist
    And the draft should appear in the new priority column on the board

  # --- Discard ---

  Scenario: Discard a draft from its detail page
    Given I am on an existing draft's detail page
    When I click "Discard"
    Then the draft should be soft-archived
    And I should be returned to the drafts board
    And the draft should no longer appear anywhere in the UI

  # --- Launch ---

  Scenario: Launch a workflow from a draft skips prompt and project selection
    Given I am on an existing draft's detail page
    When I click "Start workflow"
    And I choose a workflow type
    Then a workflow session should be created with the draft's prompt and project
    And I should land directly on the workflow runner without seeing the prompt/project form

  Scenario: Launching a workflow auto-archives the draft
    Given I have launched a workflow from a draft successfully
    When I return to the drafts board
    Then the originating draft should no longer appear

  # --- Reordering ---

  Scenario: Reorder drafts within a priority column
    Given I have multiple drafts in the High priority column
    When I drag a draft to a new position within the same column
    Then the new order should persist across reloads

  Scenario: Move a draft to a different priority column via drag-and-drop
    Given I have a draft in the Low priority column
    When I drag it into the High priority column
    Then the draft's priority should become High
    And the draft should appear in the High column on reload
