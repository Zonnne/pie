defmodule Pie.Extension do
  @moduledoc """
  Layer 5b: extensions add behaviour without touching the core.

  An extension is a module implementing some of these callbacks:

      use Pie.Extension

      def init(opts), do: {:ok, state}                        # once per start
      def tools(state), do: [%Pie.Tool{}]                      # contribute tools
      def system_prompt(prompt, state), do: prompt <> "..."    # amend the prompt
      def handle_event(event, state), do: {:ok, state}         # observe (async)
      def before_tool_call(call, state), do: :ok | {:block, reason}  # gate (sync)

  Each extension runs in its own process (`Pie.Extension.Server`) under the
  agent's tree, subscribed to the agent's events. So a buggy extension
  crashes alone and is restarted; the agent never notices. A gate whose
  extension is down or too slow *blocks* the call: a permission check that
  fails open is not a permission check.

  Files in `.pie/extensions/*.exs` (project) and `$PIE_HOME/extensions/*.exs`
  are loaded by the CLI; see `examples/extensions/`.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()}
  @callback tools(state :: term()) :: [Pie.Tool.t()]
  @callback system_prompt(prompt :: String.t(), state :: term()) :: String.t()
  @callback handle_event(event :: Pie.Agent.Event.t(), state :: term()) :: {:ok, term()}
  @callback before_tool_call(Pie.AI.ToolCall.t(), state :: term()) :: :ok | {:block, String.t()}
  @optional_callbacks init: 1, tools: 1, system_prompt: 2, handle_event: 2, before_tool_call: 2

  @gate_timeout 5_000

  defmacro __using__(_opts) do
    quote do
      @behaviour Pie.Extension
    end
  end

  @doc "True if `module` implements this behaviour."
  def extension?(module) do
    Code.ensure_loaded?(module) and
      Pie.Extension in (module.module_info(:attributes)
                        |> Keyword.get_values(:behaviour)
                        |> List.flatten())
  end

  @doc "Child specs for an agent's extensions, given as modules or `{module, opts}`."
  def child_specs(agent_id, extensions) do
    extensions
    |> Enum.map(fn
      {module, opts} -> {module, opts}
      module -> {module, []}
    end)
    |> Enum.with_index(fn {module, opts}, index ->
      Supervisor.child_spec({Pie.Extension.Server, {agent_id, index, module, opts}},
        id: {module, index}
      )
    end)
  end

  @doc "Tools contributed by an agent's extensions."
  def tools(agent_id) do
    for {pid, module} <- servers(agent_id),
        exported?(module, :tools, 1),
        tool <- call(pid, :tools, []),
        do: tool
  end

  @doc "The system prompt after every extension has amended it, in order."
  def system_prompt(agent_id, prompt) do
    agent_id
    |> servers()
    |> Enum.filter(fn {_, module} -> exported?(module, :system_prompt, 2) end)
    |> Enum.reduce(prompt, fn {pid, _}, acc -> call(pid, {:system_prompt, acc}, acc) end)
  end

  @doc "Asks every gating extension about a tool call; the first block wins."
  def before_tool_call(agent_id, call) do
    agent_id
    |> servers()
    |> Enum.filter(fn {_, module} -> exported?(module, :before_tool_call, 2) end)
    |> Enum.reduce_while(:ok, fn {pid, module}, :ok ->
      case call(pid, {:before_tool_call, call}, :unavailable) do
        :ok -> {:cont, :ok}
        {:block, reason} -> {:halt, {:block, reason}}
        _ -> {:halt, {:block, "extension #{inspect(module)} is unavailable"}}
      end
    end)
  end

  defp servers(agent_id) do
    Pie.PubSub
    |> Registry.lookup({:extensions, agent_id})
    |> Enum.sort_by(fn {_pid, {index, _}} -> index end)
    |> Enum.map(fn {pid, {_, module}} -> {pid, module} end)
  end

  defp exported?(module, fun, arity), do: function_exported?(module, fun, arity)

  defp call(pid, message, fallback) do
    GenServer.call(pid, message, @gate_timeout)
  catch
    :exit, _ -> fallback
  end
end
