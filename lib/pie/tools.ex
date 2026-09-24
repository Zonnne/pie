defmodule Pie.Tools do
  @moduledoc """
  The four default coding tools, after Pi: `read`, `bash`, `edit`, `write`.
  Everything else (ls, grep, find, tests, git) goes through `bash`.
  """

  @max_lines 2000
  @max_bytes 50_000

  @spec coding(Path.t()) :: [Pie.Tool.t()]
  def coding(cwd) do
    [
      Pie.Tools.Read.tool(cwd),
      Pie.Tools.Bash.tool(cwd),
      Pie.Tools.Edit.tool(cwd),
      Pie.Tools.Write.tool(cwd)
    ]
  end

  @doc "Resolves a user or model supplied path against `cwd`, expanding `~`."
  def resolve("~" <> rest, _cwd), do: Path.join(System.user_home!(), rest) |> Path.expand()
  def resolve(path, cwd), do: Path.expand(path, cwd)

  @doc "Keeps the first lines that fit the limits. Returns `{text, lines_kept}`."
  def head(lines, max_lines \\ @max_lines, max_bytes \\ @max_bytes) do
    {kept, _} =
      lines
      |> Enum.take(max_lines)
      |> Enum.reduce_while({[], 0}, fn line, {acc, bytes} ->
        bytes = bytes + byte_size(line) + 1

        if bytes > max_bytes and acc != [],
          do: {:halt, {acc, bytes}},
          else: {:cont, {[line | acc], bytes}}
      end)

    {kept |> Enum.reverse() |> Enum.join("\n"), length(kept)}
  end

  @doc "Keeps the last lines that fit the limits (command output: the end matters)."
  def tail(text, max_lines \\ @max_lines, max_bytes \\ @max_bytes) do
    lines = String.split(text, "\n")
    {kept, count} = head(Enum.reverse(lines), max_lines, max_bytes)
    kept = kept |> String.split("\n") |> Enum.reverse() |> Enum.join("\n")
    dropped = length(lines) - count
    if dropped > 0, do: "[#{dropped} earlier lines truncated]\n" <> kept, else: kept
  end
end
