defmodule Pie.Agent.Scheduler do
  @moduledoc """
  Runs the tool calls of one assistant turn.

  Each call runs in its own process under `Pie.TaskSupervisor`, linked to the
  loop. That one decision buys crash isolation (a raising tool becomes an
  error result), timeouts (kill the process) and cancellation (kill the
  process; see D-010) without any cooperation from tool authors.

  Scheduling rule: calls start in order. A tool marked `parallel: true` may
  start while other parallel tools are running (up to `max_concurrency`); any
  other tool waits until nothing is running and runs alone. So reads fan out
  and writes stay ordered.

  Invariant: every call yields exactly one `Pie.AI.ToolResultMessage`, whether
  it succeeded, failed validation, was blocked, crashed, timed out or was
  aborted. Results are returned in call order, so logs are deterministic
  whatever the timing. Observers see `tool_execution_*` events live.
  """
  alias Pie.AI.{Message, Text, ToolResultMessage}
  alias Pie.Tool

  @spec run([Pie.AI.ToolCall.t()], Pie.Agent.Loop.Config.t()) ::
          {[ToolResultMessage.t()], boolean()}
  def run(calls, config) do
    state = %{
      queue: Enum.with_index(calls, fn call, i -> {i, call} end),
      running: %{},
      results: %{},
      aborted: false,
      tools: Map.new(config.tools, &{&1.name, &1}),
      config: config
    }

    state = schedule(state)
    results = state.results |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {results, state.aborted}
  end

  defp schedule(state) do
    state = start_ready(state)

    if state.queue == [] and state.running == %{},
      do: state,
      else: state |> await() |> schedule()
  end

  defp start_ready(%{queue: [{i, call} | rest]} = state) do
    tool = state.tools[call.name]

    if startable?(tool, state) do
      %{state | queue: rest} |> start(i, call, tool) |> start_ready()
    else
      state
    end
  end

  defp start_ready(state), do: state

  defp startable?(_tool, %{running: running}) when map_size(running) == 0, do: true

  defp startable?(tool, state) do
    parallel?(tool) and map_size(state.running) < state.config.max_concurrency and
      Enum.all?(state.running, fn {_, {_, call, _, _}} -> parallel?(state.tools[call.name]) end)
  end

  defp parallel?(%Tool{parallel: parallel}), do: parallel
  defp parallel?(nil), do: false

  defp start(state, i, call, tool) do
    emit(state, {:tool_execution_start, call})

    case prepare(call, tool, state.config) do
      :ok ->
        loop = self()
        task = Task.Supervisor.async(Pie.TaskSupervisor, fn -> execute(tool, call, loop) end)

        timer =
          if tool.timeout != :infinity,
            do: Process.send_after(self(), {:tool_timeout, task.ref}, tool.timeout)

        put_in(state.running[task.ref], {i, call, task, timer})

      {:error, reason} ->
        record(state, i, call, {:error, reason})
    end
  end

  defp prepare(call, nil, _config), do: {:error, "Tool \"#{call.name}\" not found"}

  defp prepare(call, tool, config) do
    with :ok <- invalid(Tool.validate(tool.parameters, call.arguments), call),
         :ok <- blocked(config.before_tool_call.(call)) do
      :ok
    end
  end

  defp invalid(:ok, _call), do: :ok

  defp invalid({:error, reason}, call),
    do: {:error, "Invalid arguments for #{call.name}: #{reason}"}

  defp blocked(:ok), do: :ok
  defp blocked({:block, reason}), do: {:error, "Blocked: #{reason}"}

  defp execute(tool, call, loop) do
    update = fn partial -> send(loop, {:tool_update, call.id, partial}) end
    tool.execute.(call.arguments, %{tool_call_id: call.id, update: update})
  end

  defp await(state) do
    %{running: running, config: %{signal: signal, parent: parent}} = state

    receive do
      {ref, value} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        finish(state, ref, normalize(value))

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        finish(state, ref, {:error, "Tool crashed: " <> Exception.format_exit(reason)})

      {:tool_timeout, ref} when is_map_key(running, ref) ->
        {_, _, task, _} = running[ref]
        Task.shutdown(task, :brutal_kill)
        finish(state, ref, {:error, "Tool timed out"})

      {:tool_update, id, partial} ->
        case Enum.find(running, fn {_, {_, call, _, _}} -> call.id == id end) do
          {_, {_, call, _, _}} -> emit(state, {:tool_execution_update, call, partial})
          nil -> :ok
        end

        state

      {:abort, ^signal} ->
        abort_all(state)

      {:EXIT, ^parent, reason} ->
        abort_all(state)
        exit(reason)

      {:EXIT, _pid, _reason} ->
        # A linked tool task exited; its reply or :DOWN carries the outcome.
        state
    end
  end

  defp finish(state, ref, outcome) do
    {{i, call, task, timer}, running} = Map.pop(state.running, ref)
    forget(task, timer)
    record(%{state | running: running}, i, call, outcome)
  end

  # Leave no stray timer or exit messages behind in the loop's mailbox.
  defp forget(task, timer) do
    if timer do
      Process.cancel_timer(timer)

      receive do
        {:tool_timeout, ref} when ref == task.ref -> :ok
      after
        0 -> :ok
      end
    end

    Process.unlink(task.pid)

    receive do
      {:EXIT, pid, _} when pid == task.pid -> :ok
    after
      0 -> :ok
    end
  end

  defp abort_all(state) do
    state =
      Enum.reduce(state.running, state, fn {ref, {_, _, task, _}}, state ->
        Task.shutdown(task, :brutal_kill)
        finish(state, ref, {:error, "Aborted"})
      end)

    state =
      Enum.reduce(state.queue, state, fn {i, call}, state ->
        emit(state, {:tool_execution_start, call})
        record(state, i, call, {:error, "Skipped: the run was aborted"})
      end)

    %{state | queue: [], aborted: true}
  end

  defp record(state, i, call, outcome) do
    {content, details, error?} =
      case outcome do
        {:ok, text, details} -> {text, details, false}
        {:error, text} -> {text, nil, true}
      end

    result = %ToolResultMessage{
      tool_call_id: call.id,
      tool_name: call.name,
      content: [%Text{text: content}],
      details: details,
      is_error: error?,
      timestamp: Message.now()
    }

    emit(state, {:tool_execution_end, call, result})
    put_in(state.results[i], result)
  end

  defp normalize({:ok, text}) when is_binary(text), do: {:ok, text, nil}
  defp normalize({:ok, text, details}) when is_binary(text), do: {:ok, text, details}
  defp normalize({:error, text}) when is_binary(text), do: {:error, text}
  defp normalize({:error, other}), do: {:error, inspect(other)}
  defp normalize(other), do: {:error, "Tool returned an invalid value: #{inspect(other)}"}

  defp emit(state, event), do: state.config.emit.(event)
end
