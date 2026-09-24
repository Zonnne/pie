defmodule Pie.Tools.Edit do
  @moduledoc """
  Replaces one exact, unique occurrence of `oldText` with `newText`.
  Uniqueness is what makes the edit safe: an ambiguous match is an error the
  model can fix by quoting more context.
  """

  def tool(cwd) do
    %Pie.Tool{
      name: "edit",
      description:
        "Edit a file by replacing exact text. oldText must match exactly (including " <>
          "whitespace) and occur exactly once; include surrounding lines to make it unique.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file (relative or absolute)"},
          oldText: %{type: "string", description: "Exact text to replace"},
          newText: %{type: "string", description: "Replacement text"}
        },
        required: ["path", "oldText", "newText"]
      },
      execute: &execute(&1, &2, cwd)
    }
  end

  def execute(%{"path" => rel, "oldText" => old, "newText" => new}, _ctx, cwd) do
    path = Pie.Tools.resolve(rel, cwd)

    with {:ok, content} <- read(path, rel),
         {:ok, position} <- locate(content, old, rel),
         :ok <- write(path, rel, String.replace(content, old, new, global: false)) do
      line = content |> binary_part(0, position) |> String.split("\n") |> length()
      {:ok, "Edited #{rel} at line #{line}", %{line: line}}
    end
  end

  defp read(path, rel) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{rel}: #{:file.format_error(reason)}"}
    end
  end

  defp locate(_content, "", _rel), do: {:error, "oldText must not be empty"}

  defp locate(content, old, rel) do
    case :binary.matches(content, old) do
      [{position, _}] ->
        {:ok, position}

      [] ->
        {:error, "Could not find oldText in #{rel}. It must match exactly, including whitespace."}

      matches ->
        {:error,
         "oldText occurs #{length(matches)} times in #{rel}; include more context to make it unique."}
    end
  end

  defp write(path, rel, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot write #{rel}: #{:file.format_error(reason)}"}
    end
  end
end
