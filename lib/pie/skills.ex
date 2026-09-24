defmodule Pie.Skills do
  @moduledoc """
  Layer 5d: skills, loaded on demand.

  A skill is a directory containing a `SKILL.md` whose frontmatter has a
  `name` and a `description`. Only those two lines and the file's location go
  into the system prompt; when a task matches, the model reads the file with
  the `read` tool and follows it. Instructions cost context only when used.

  Skills are discovered in `.pie/skills/` (project) then `$PIE_HOME/skills/`
  (global); the first skill with a given name wins.
  """

  defstruct [:name, :description, :path]
  @type t :: %__MODULE__{name: String.t(), description: String.t(), path: Path.t()}

  def default_dirs(cwd), do: [Path.join(cwd, ".pie/skills"), Path.join(Pie.home(), "skills")]

  @spec discover([Path.t()]) :: [t()]
  def discover(dirs) do
    dirs
    |> Enum.flat_map(&(&1 |> Path.join("*/SKILL.md") |> Path.wildcard() |> Enum.sort()))
    |> Enum.flat_map(&load/1)
    |> Enum.uniq_by(& &1.name)
  end

  @doc "Parses one SKILL.md; skills without a description are skipped."
  def load(path) do
    with {:ok, text} <- File.read(path),
         %{"description" => description} = meta when description != "" <- frontmatter(text) do
      [
        %__MODULE__{
          name: meta["name"] || Path.basename(Path.dirname(path)),
          description: description,
          path: path
        }
      ]
    else
      _ -> []
    end
  end

  # A deliberately tiny subset of YAML: `key: value` lines between `---` fences.
  defp frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [yaml, _body] ->
        for line <- String.split(yaml, "\n"),
            [key, value] <- [String.split(line, ":", parts: 2)],
            into: %{},
            do: {String.trim(key), value |> String.trim() |> String.trim("\"")}

      _ ->
        %{}
    end
  end

  defp frontmatter(_no_frontmatter), do: %{}

  @doc "The system prompt section listing the skills."
  def prompt_section([]), do: ""

  def prompt_section(skills) do
    entries =
      Enum.map_join(skills, "\n", fn s ->
        "  <skill>\n    <name>#{s.name}</name>\n    <description>#{s.description}</description>\n" <>
          "    <location>#{s.path}</location>\n  </skill>"
      end)

    """
    The following skills provide specialized instructions for specific tasks. When a task \
    matches a skill's description, read the skill file at its location first and follow it. \
    Paths inside a skill are relative to the skill's directory.

    <available_skills>
    #{entries}
    </available_skills>\
    """
  end
end
