defmodule Destila.Drafts.DraftTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Drafts.Draft

  describe "changeset/2" do
    test "requires prompt, priority, position, and project_id" do
      changeset = Draft.changeset(%Draft{}, %{})
      refute changeset.valid?
      assert changeset.errors[:prompt]
      assert changeset.errors[:priority]
      assert changeset.errors[:position]
      assert changeset.errors[:project_id]
    end

    test "accepts a valid set of attributes" do
      attrs = %{
        prompt: "Refactor the thing",
        priority: :high,
        position: 1.0,
        project_id: Ecto.UUID.generate()
      }

      changeset = Draft.changeset(%Draft{}, attrs)
      assert changeset.valid?
    end

    test "rejects unknown priority values" do
      attrs = %{
        prompt: "p",
        priority: "banana",
        position: 1.0,
        project_id: Ecto.UUID.generate()
      }

      changeset = Draft.changeset(%Draft{}, attrs)
      refute changeset.valid?
      assert changeset.errors[:priority]
    end
  end
end
