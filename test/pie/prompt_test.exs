defmodule Pie.PromptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "lists tools with matching guidelines and ends with the environment", %{tmp_dir: dir} do
    prompt =
      Pie.Prompt.build(
        cwd: dir,
        tools: Pie.Tools.coding(dir),
        context_files: [],
        date: ~D[2026-01-02]
      )

    assert prompt =~ "- read: Read the contents of a file\n"
    assert prompt =~ "- bash: Execute a bash command in the working directory\n"
    assert prompt =~ "oldText must match exactly"

    assert String.ends_with?(
             prompt,
             "Current date: 2026-01-02\nCurrent working directory: #{dir}"
           )

    refute prompt =~ "Project context"
  end

  test "collects AGENTS.md / CLAUDE.md from the root down to cwd", %{tmp_dir: dir} do
    nested = Path.join(dir, "app/lib")
    File.mkdir_p!(nested)
    File.write!(Path.join(dir, "AGENTS.md"), "outer rules")
    File.write!(Path.join(dir, "app/CLAUDE.md"), "inner rules")
    File.write!(Path.join(nested, "AGENTS.md"), "innermost rules")

    files = Pie.Prompt.context_files(nested) |> Enum.map(&elem(&1, 1))
    assert Enum.take(files, -3) == ["outer rules", "inner rules", "innermost rules"]

    prompt = Pie.Prompt.build(cwd: nested, tools: [])
    assert prompt =~ ~r/outer rules.*inner rules.*innermost rules/s
  end
end
