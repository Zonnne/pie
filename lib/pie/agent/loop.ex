defmodule Pie.Agent.Loop do
  @moduledoc """
  Layer 2: the smallest correct tool loop.

  `run/3` is a plain function: it takes new prompt messages, the history, and
  a config, and returns the messages it added. It has no state of its own and
  talks to the outside world only through the callbacks in `Config`, which is
  what lets the runtime (`Pie.Agent`) run it in a supervised task, and tests
  run it directly.

      turn:  stream a reply → run its tool calls → append the results
      then:  steering queued?  → next turn with those messages
             tool calls made?  → next turn (the model sees the results)
             follow-up queued? → next turn with those messages
             otherwise         → done

  A turn that ends in `:error` or `:aborted` ends the run. Every transition
  is reported through `config.emit` (see `Pie.Agent.Event`).
  """
  alias Pie.AI
  alias Pie.AI.{Context, Message}
  alias Pie.Agent.Scheduler

  defmodule Config do
    @moduledoc """
    Everything a run needs. Callbacks default to no-ops.

      * `emit` – receives every lifecycle event
      * `steering` / `follow_up` – return queued messages (see `Pie.Agent.Loop`)
      * `before_tool_call` – a gate: `:ok` or `{:block, reason}`
      * `transform_context` – projects history before each model call
      * `signal` – abort signal (see `Pie.AI`); `parent` – a pid whose exit
        ends the run
    """
    @enforce_keys [:model]
    defstruct [
      :model,
      :signal,
      :parent,
      system_prompt: nil,
      tools: [],
      stream_opts: [],
      max_concurrency: 4,
      emit: &Pie.Agent.Loop.ignore/1,
      steering: &Pie.Agent.Loop.none/0,
      follow_up: &Pie.Agent.Loop.none/0,
      before_tool_call: &Pie.Agent.Loop.allow/1,
      transform_context: &Function.identity/1
    ]

    @type t :: %__MODULE__{}
  end

  @doc false
  def ignore(_event), do: :ok
  @doc false
  def none, do: []
  @doc false
  def allow(_call), do: :ok

  @spec run([Message.t()], [Message.t()], Config.t()) :: [Message.t()]
  def run(prompts, history, %Config{} = config) do
    # Tool tasks are linked to this process: they die with it, and we trap
    # their exits so a crashing tool becomes an error result instead.
    previous = Process.flag(:trap_exit, true)

    try do
      config = %{config | signal: config.signal || make_ref()}
      emit(config, :agent_start)
      state = turn(%{messages: history, new: []}, prompts, config)
      new = Enum.reverse(state.new)
      emit(config, {:agent_end, new})
      new
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp turn(state, pending, config) do
    check_parent(config)
    emit(config, :turn_start)
    state = Enum.reduce(pending, state, &commit(&2, &1, config))
    message = stream_reply(state, config)
    state = append(state, message)

    if message.stop_reason in [:error, :aborted] do
      emit(config, {:turn_end, message, []})
      state
    else
      calls = Message.tool_calls(message)
      {results, aborted?} = if calls == [], do: {[], false}, else: Scheduler.run(calls, config)
      state = Enum.reduce(results, state, &commit(&2, &1, config))
      emit(config, {:turn_end, message, results})
      if aborted?, do: state, else: continue(state, calls, config)
    end
  end

  defp continue(state, calls, config) do
    case {config.steering.(), calls} do
      {[_ | _] = steering, _} ->
        turn(state, steering, config)

      {[], [_ | _]} ->
        turn(state, [], config)

      {[], []} ->
        case config.follow_up.() do
          [] -> state
          follow_ups -> turn(state, follow_ups, config)
        end
    end
  end

  defp stream_reply(state, config) do
    context = %Context{
      system_prompt: config.system_prompt,
      messages: state.messages |> config.transform_context.() |> Enum.filter(&Message.llm?/1),
      tools: config.tools
    }

    config.model
    |> AI.stream(context, [signal: config.signal] ++ config.stream_opts)
    |> Enum.reduce(nil, fn
      {:start, partial}, _ ->
        emit(config, {:message_start, partial})
        nil

      {type, _reason, message}, _ when type in [:done, :error] ->
        emit(config, {:message_end, message})
        message

      event, acc ->
        emit(config, {:message_update, event})
        acc
    end)
  end

  defp commit(state, message, config) do
    emit(config, {:message_start, message})
    emit(config, {:message_end, message})
    append(state, message)
  end

  defp append(state, message) do
    %{state | messages: state.messages ++ [message], new: [message | state.new]}
  end

  defp check_parent(%Config{parent: nil}), do: :ok

  defp check_parent(%Config{parent: parent}) do
    receive do
      {:EXIT, ^parent, reason} -> exit({:shutdown, {:parent_exited, reason}})
    after
      0 -> :ok
    end
  end

  defp emit(config, event), do: config.emit.(event)
end
