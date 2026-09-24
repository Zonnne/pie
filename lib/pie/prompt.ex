defmodule Pie.Prompt do
  @moduledoc """
  Layer 5a: the system prompt.

  Pi's system prompt is famously small, and so is this one: who you are,
  which tools exist, a few guidelines, then the project's own instructions.
  Everything specific to a codebase belongs in `AGENTS.md` (or `CLAUDE.md`)
  files, which are collected from `$PIE_HOME/AGENTS.md` and from every
  directory between the filesystem root and the working directory, outermost
  first, so the most specific instructions come last.
  """

  @guidelines %{
    "bash" => "Use bash for exploration (ls, rg, find), running tests and git.",
    "read" => "Read files before editing them.",
    "edit" => "Use edit for precise changes; oldText must match exactly and be unique.",
    "write" => "Use write only for new files or complete rewrites."
  }

  @doc """
  Options: `:cwd` (required), `:tools`, `:skills` (see `Pie.Skills`),
  `:context_files` (list of `{path, content}`; discovered when omitted),
  `:date`.
  """
  @spec build(keyword()) :: String.t()
  def build(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    tools = Keyword.get(opts, :tools, [])
    files = Keyword.get_lazy(opts, :context_files, fn -> context_files(cwd) end)

    date =
      Keyword.get_lazy(opts, :date, fn -> NaiveDateTime.local_now() |> NaiveDateTime.to_date() end)

    [
      intro(tools),
      project_context(files),
      Pie.Skills.prompt_section(Keyword.get(opts, :skills, [])),
      "Current date: #{date}\nCurrent working directory: #{cwd}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp intro(tools) do
    tool_lines = Enum.map_join(tools, "\n", &"- #{&1.name}: #{summary(&1.description)}")
    guidelines = for t <- tools, line = @guidelines[t.name], do: "- #{line}"

    guidelines =
      Enum.join(
        guidelines ++
          [
            "- When you are done, summarize what you did in plain text; do not use tools to display it.",
            "- Be concise. Show file paths clearly when you refer to files."
          ],
        "\n"
      )

    """
    You are an expert coding assistant working inside pie, a minimal coding agent. \
    You help users with software engineering tasks by reading files, running commands, \
    editing code and writing new files.

    Available tools:
    #{if tool_lines == "", do: "(none)", else: tool_lines}

    Guidelines:
    #{guidelines}\
    """
  end

  defp summary(description),
    do: description |> String.split(". ", parts: 2) |> hd() |> String.trim_trailing(".")

  defp project_context([]), do: ""

  defp project_context(files) do
    sections =
      Enum.map_join(files, "\n\n", fn {path, content} ->
        "## #{path}\n\n#{String.trim(content)}"
      end)

    "# Project context\n\nThe user provided these instructions; follow them.\n\n" <> sections
  end

  @doc "Instruction files for `cwd`, outermost first, as `{path, content}`."
  def context_files(cwd) do
    global = Path.join(Pie.home(), "AGENTS.md")

    dirs =
      cwd
      |> Path.expand()
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))

    candidates =
      [global] ++
        Enum.flat_map(dirs, fn dir ->
          ["AGENTS.md", "CLAUDE.md"]
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.take(1)
        end)

    for path <- Enum.uniq(candidates), File.regular?(path), do: {path, File.read!(path)}
  end
end
