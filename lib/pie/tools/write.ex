defmodule Pie.Tools.Write do
  @moduledoc "Writes a whole file, creating parent directories."

  def tool(cwd) do
    %Pie.Tool{
      name: "write",
      description:
        "Write content to a file, creating it (and parent directories) if needed and " <>
          "overwriting it otherwise. Use for new files or complete rewrites.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file (relative or absolute)"},
          content: %{type: "string", description: "The full content to write"}
        },
        required: ["path", "content"]
      },
      execute: &execute(&1, &2, cwd)
    }
  end

  def execute(%{"path" => rel, "content" => content}, _ctx, cwd) do
    path = Pie.Tools.resolve(rel, cwd)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{rel}"}
    else
      {:error, reason} -> {:error, "Cannot write #{rel}: #{:file.format_error(reason)}"}
    end
  end
end
