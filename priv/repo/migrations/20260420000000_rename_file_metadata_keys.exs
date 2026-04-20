defmodule Destila.Repo.Migrations.RenameFileMetadataKeys do
  use Ecto.Migration

  def up do
    # Rewrite single-key metadata values whose key is `text_file` or
    # `video_file` into the unified `file` key. Multi-key maps are left
    # alone to preserve the invariant enforced by `valid_exported_value?/1`.
    execute("""
    UPDATE workflow_session_metadata
    SET value = json_object('file', json_extract(value, '$.text_file'))
    WHERE json_extract(value, '$.text_file') IS NOT NULL
      AND (SELECT count(*) FROM json_each(value)) = 1
    """)

    execute("""
    UPDATE workflow_session_metadata
    SET value = json_object('file', json_extract(value, '$.video_file'))
    WHERE json_extract(value, '$.video_file') IS NOT NULL
      AND (SELECT count(*) FROM json_each(value)) = 1
    """)
  end

  def down do
    # Reverse using the file extension. `.mp4` goes back to `video_file`;
    # everything else goes back to `text_file`.
    execute("""
    UPDATE workflow_session_metadata
    SET value = json_object('video_file', json_extract(value, '$.file'))
    WHERE json_extract(value, '$.file') IS NOT NULL
      AND lower(substr(json_extract(value, '$.file'), -4)) = '.mp4'
      AND (SELECT count(*) FROM json_each(value)) = 1
    """)

    execute("""
    UPDATE workflow_session_metadata
    SET value = json_object('text_file', json_extract(value, '$.file'))
    WHERE json_extract(value, '$.file') IS NOT NULL
      AND (SELECT count(*) FROM json_each(value)) = 1
    """)
  end
end
