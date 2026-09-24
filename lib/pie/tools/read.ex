defmodule Pie.Tools.Read do
  @moduledoc "Reads a text file, paging with `offset`/`limit` when it is large."

  def tool(cwd) do
    %Pie.Tool{
      name: "read",
      description:
        "Read the contents of a file. Output is truncated to 2000 lines or 50KB; " <>
          "use offset/limit to page through large files.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file (relative or absolute)"},
          offset: %{type: "integer", description: "Line number to start reading from (1-indexed)"},
          limit: %{type: "integer", description: "Maximum number of lines to read"}
        },
        required: ["path"]
      },
      parallel: true,
      execute: &execute(&1, &2, cwd)
    }
  end

  def execute(args, _ctx, cwd) do
    path = Pie.Tools.resolve(args["path"], cwd)

    with {:ok, content} <- File.read(path),
         true <- String.valid?(content) || {:error, :binary} do
      lines = String.split(content, "\n")
      total = length(lines)
      offset = max(args["offset"] || 1, 1)

      if offset > total do
        {:error, "Offset #{offset} is beyond the end of the file (#{total} lines)"}
      else
        selected = Enum.drop(lines, offset - 1)

        selected =
          if args["limit"], do: Enum.take(selected, max(args["limit"], 1)), else: selected

        {text, shown} = Pie.Tools.head(selected)
        last = offset + shown - 1

        if last < total,
          do:
            {:ok,
             text <>
               "\n\n[Showing lines #{offset}-#{last} of #{total}. Use offset=#{last + 1} to continue.]"},
          else: {:ok, text}
      end
    else
      {:error, :binary} -> {:error, "#{args["path"]} looks like a binary file"}
      {:error, reason} -> {:error, "Cannot read #{args["path"]}: #{:file.format_error(reason)}"}
    end
  end
end
