# Blocks writes and edits to sensitive paths, after Pi's protected-paths
# example. Copy to .pie/extensions/ (project) or ~/.pie/extensions/ (global).
defmodule ProtectedPaths do
  use Pie.Extension

  @impl true
  def init(opts), do: {:ok, Keyword.get(opts, :patterns, [".env", ".git/", "node_modules/"])}

  @impl true
  def before_tool_call(%{name: name, arguments: %{"path" => path}}, patterns)
      when name in ["write", "edit"] do
    case Enum.find(patterns, &String.contains?(path, &1)) do
      nil -> :ok
      pattern -> {:block, "#{path} is protected (matches #{inspect(pattern)})"}
    end
  end

  def before_tool_call(_call, _patterns), do: :ok

  @impl true
  def system_prompt(prompt, patterns) do
    prompt <> "\n\nNever modify paths matching: #{Enum.join(patterns, ", ")}"
  end
end
