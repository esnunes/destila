Feature: Video Metadata Viewing
  When a workflow exports video_file-type metadata, it is displayed inline
  in the chat using a video card component. Users can play the video directly
  in the chat or open a larger modal from the metadata sidebar. Videos are
  served via a streaming endpoint that reads MP4 files from the local filesystem.

  Background:
    Given a session has exported video_file metadata

  Scenario: Video card displays with click-to-play controls
    Then the video card should display an HTML5 video player
    And the player should show standard playback controls
    And the video should not be playing

  Scenario: Play video inline
    When I click the play button on the video card
    Then the video should start playing

  Scenario: Open video in modal from sidebar
    When I click the play button on the sidebar video entry
    Then a modal overlay should appear
    And the modal should contain a larger video player
    And the modal video should have playback controls

  Scenario: Close video modal
    Given the video modal is open
    When I close the modal
    Then the modal should disappear
    And the inline video card should still be visible

  Scenario: Video file is streamed from disk
    Given the exported video_file path points to a valid MP4 file
    Then the video player source should load via the streaming endpoint
    And the video should be playable
