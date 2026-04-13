defmodule Destila.Workflows.Skills do
  @moduledoc """
  Discovers and loads skill files from priv/skills/.

  A skill is a markdown file with YAML frontmatter containing at minimum
  `name` and `always` fields. Skills marked `always: true` are injected into
  every AI prompt. Other skills are loaded on-demand by identifier.
  """

  @skills_dir "priv/skills"

  @doc """
  Returns all skills marked with `always: true`.
  """
  def always_included do
    all_skills()
    |> Enum.filter(& &1.always)
  end

  @doc """
  Returns skills matching the given identifiers (filenames without extension).
  """
  def by_identifiers(identifiers) do
    all = all_skills()
    Enum.filter(all, &(&1.identifier in identifiers))
  end

  @doc """
  Returns the rendered skills section for always-included + phase skills.
  Each skill is rendered as `## Skill: <name>\n\n<body>`.
  Returns an empty string when no skills apply.
  """
  def assemble_skills(phase_skills) do
    skills = always_included() ++ by_identifiers(phase_skills)
    skills = Enum.uniq_by(skills, & &1.identifier)

    Enum.map_join(skills, "\n\n", fn skill ->
      "## Skill: #{skill.name}\n\n#{skill.body}"
    end)
  end

  @doc """
  Returns all parsed skills from priv/skills/.
  """
  def all_skills do
    skills_path = Application.app_dir(:destila, @skills_dir)

    skills_path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse_skill_file/1)
  end

  defp parse_skill_file(path) do
    content = File.read!(path)
    {frontmatter, body} = split_frontmatter(content)

    %{
      identifier: Path.basename(path, ".md"),
      name: parse_field(frontmatter, "name"),
      always: parse_field(frontmatter, "always") == "true",
      body: String.trim(body)
    }
  end

  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, content) do
      [_, frontmatter, body] -> {frontmatter, body}
    end
  end

  defp parse_field(frontmatter, field) do
    case Regex.run(~r/^#{field}:\s*(.+)$/m, frontmatter) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
