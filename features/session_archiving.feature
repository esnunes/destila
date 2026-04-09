Feature: Session Archiving
  Users can archive workflow sessions to hide them from the crafting board and
  dashboard. Archived sessions are accessible from a dedicated archived sessions
  page and can be restored.

  # --- Archiving ---

  Scenario: Archive a session from the session detail page
    Given I am viewing a session titled "Fix login bug"
    When I click the "Archive" button
    Then I should be redirected to the crafting board
    And I should see a flash message confirming the session was archived

  Scenario: Archived session is hidden from the crafting board
    Given I have archived a session titled "Fix login bug"
    When I navigate to the crafting board
    Then I should not see the session "Fix login bug"

  Scenario: Archived session is hidden from the dashboard
    Given I have archived a session titled "Fix login bug"
    When I navigate to the dashboard
    Then I should not see the session "Fix login bug"

  # --- Unarchiving ---

  Scenario: Unarchive a session from the session detail page
    Given I am viewing an archived session titled "Fix login bug"
    And the button label shows "Unarchive"
    When I click the "Unarchive" button
    Then I should see a flash message confirming the session was restored
    And the button label should change to "Archive"

  Scenario: Restored session reappears on the crafting board
    Given I have restored a previously archived session titled "Fix login bug"
    When I navigate to the crafting board
    Then I should see the session "Fix login bug"

  # --- Archived Sessions Page ---

  Scenario: View archived sessions on a dedicated page
    Given I have archived sessions "Fix login bug" and "Refactor auth"
    When I navigate to the archived sessions page
    Then I should see "Fix login bug" and "Refactor auth" in the list

  Scenario: Navigate to archived session detail from archived page
    Given I am on the archived sessions page
    When I click on the session "Fix login bug"
    Then I should be navigated to the session detail page for "Fix login bug"

  Scenario: Archived page is empty when no sessions are archived
    Given no sessions are archived
    When I navigate to the archived sessions page
    Then I should see a message indicating there are no archived sessions
