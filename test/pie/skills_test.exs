defmodule Pie.SkillsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp skill(dir, name, body) do
    File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join([dir, name, "SKILL.md"]), body)
  end

  test "discovers skills by frontmatter; the first directory wins", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    global = Path.join(dir, "global")
    skill(project, "pdf", "---\nname: pdf\ndescription: \"Work with PDF files\"\n---\n# Steps\n")
    skill(global, "pdf", "---\nname: pdf\ndescription: global copy\n---\n")
    skill(global, "deploy", "---\ndescription: Deploy the app\n---\nbody")
    skill(global, "broken", "no frontmatter here")

    skills = Pie.Skills.discover([project, global])

    assert Enum.map(skills, &{&1.name, &1.description}) == [
             {"pdf", "Work with PDF files"},
             {"deploy", "Deploy the app"}
           ]

    prompt = Pie.Prompt.build(cwd: dir, tools: [], skills: skills, context_files: [])
    assert prompt =~ "<available_skills>"
    assert prompt =~ "<location>#{Path.join([project, "pdf", "SKILL.md"])}</location>"
    refute prompt =~ "global copy"
  end

  test "no skills, no section", %{tmp_dir: dir} do
    refute Pie.Prompt.build(cwd: dir, tools: [], skills: [], context_files: []) =~
             "available_skills"
  end
end
