Feature: Session Deletion
  Users can permanently delete workflow sessions from the session detail page.
  Deleted sessions are hidden from every UI surface, cannot be restored from the
  UI, and still count toward the project-deletion guard. Recovery is console-only.

  # --- Deleting from the session detail page ---

  Scenario: Delete a session from the session detail page
    Given I am viewing a session titled "Fix login bug"
    When I click the "Delete" button
    And I confirm the browser prompt
    Then the session should be soft-deleted
    And I should be redirected to the page I came from, falling back to the crafting board
    And I should see a flash message confirming the session was deleted

  Scenario: Cancel the delete confirmation dialog
    Given I am viewing a session titled "Fix login bug"
    When I click the "Delete" button
    And I cancel the browser prompt
    Then the session should not be deleted
    And I should remain on the session detail page

  # --- Hidden from listings ---

  Scenario: Deleted session is hidden from the crafting board
    Given I have deleted a session titled "Fix login bug"
    When I navigate to the crafting board
    Then I should not see the session "Fix login bug"

  Scenario: Deleted session is hidden from the archived sessions page
    Given I have archived a session titled "Fix login bug"
    And I have deleted that archived session
    When I navigate to the archived sessions page
    Then I should not see the session "Fix login bug"

  Scenario: Deleted session detail page is no longer accessible
    Given I have deleted a session titled "Fix login bug"
    When I navigate directly to that session's detail page
    Then I should be redirected to the crafting board
    And I should see a flash message indicating the session was not found

  # --- Deletion is always available ---

  Scenario: Delete an archived session
    Given I am viewing an archived session titled "Fix login bug"
    When I click the "Delete" button
    And I confirm the browser prompt
    Then the session should be soft-deleted
    And it should no longer appear on the archived sessions page

  # --- Cleanup on delete ---

  Scenario: Deleting a running session stops its service and AI sessions
    Given I have a running session with an active service and AI session
    When I delete the session
    Then the service should be stopped
    And the AI sessions for that workflow should be stopped

  # --- Project deletion guard ---

  Scenario: Deleted sessions still block project deletion
    Given I have a project with a single session
    And I have deleted that session
    When I try to delete the project
    Then the deletion should be blocked because the project still has linked sessions
