defmodule Pie.Agent do
  @moduledoc """
  Layer 3: the concurrent runtime, with every lifecycle transition observable.

  An agent is a GenServer that owns the conversation state and runs one loop
  at a time (`Pie.Agent.Loop`) in a supervised task:

      caller ──prompt──▶ Pie.Agent ──spawn──▶ loop task ──▶ tool tasks
                           ▲   │                  │
                           │   └── broadcast ◀────┘ {:run_event, run_id, event}
                           └── dequeue steering/follow-ups (call)

  The loop reports every event to the agent, which updates its state first
  and then broadcasts the event to subscribers. So a subscriber that sees
  `{:message_end, m}` knows `m` is already part of the agent's state. Events
  from a run that has since been aborted or replaced are dropped by run id.

  The loop task is linked to the agent (which traps exits): if the agent
  dies, the run dies with it; if the run crashes, the agent survives, reports
  `{:run_crashed, reason}` and goes idle.

  Tools and the system prompt are extended at start by the agent's
  extensions (`Pie.Extension`), which also gate every tool call.

  After each run, if the context is near the model's window, the agent
  compacts it (`Pie.Compaction`) in a task of its own; `compact/2` does the
  same on request. Prompts are refused while compacting; queued messages
  wait for it to finish.

  Every agent has a `Pie.Session` (layer 4). Its messages are the session's
  context projection, loaded at start, and each `message_end` is appended to
  the session *before* it is broadcast, so a subscriber never sees a message
  that could be lost. Restarting an agent re-hydrates it from the log.
  """
  use GenServer

  alias Pie.AI.{AssistantMessage, UserMessage}
  alias Pie.Agent.Loop

  defstruct [
    :id,
    :model,
    :session,
    system_prompt: nil,
    tools: [],
    messages: [],
    stream_opts: [],
    max_concurrency: 4,
    transform_context: &Function.identity/1,
    compaction: Pie.Compaction.defaults(),
    status: :idle,
    run: nil,
    stream_message: nil,
    pending_tools: MapSet.new(),
    timers: %{},
    steering: [],
    follow_up: [],
    waiters: [],
    error: nil
  ]

  @type agent :: String.t() | pid()
  @type input :: String.t() | UserMessage.t() | [UserMessage.t()]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  def via(id), do: {:via, Registry, {Pie.Registry, {:agent, id}}}

  @doc "Starts a run. Fails with `{:error, status}` unless the agent is idle."
  @spec prompt(agent(), input()) :: :ok | {:error, :running | :compacting}
  def prompt(agent, input), do: GenServer.call(server(agent), {:prompt, to_messages(input)})

  @doc """
  Queues a message for delivery after the current turn's tools finish (or
  starts a run when idle). Returns whether it started a run or was queued.
  """
  @spec steer(agent(), input()) :: {:ok, :started | :queued}
  def steer(agent, input),
    do: GenServer.call(server(agent), {:enqueue, :steering, to_messages(input)})

  @doc "Queues a message for when the agent would otherwise stop."
  @spec follow_up(agent(), input()) :: {:ok, :started | :queued}
  def follow_up(agent, input),
    do: GenServer.call(server(agent), {:enqueue, :follow_up, to_messages(input)})

  @doc "Aborts the current run (the partial reply is kept) and clears queued messages."
  def abort(agent), do: GenServer.call(server(agent), :abort)

  @doc "Summarizes older history to free context. Only while idle."
  @spec compact(agent(), String.t() | nil) :: :ok | {:error, :running | :compacting}
  def compact(agent, instructions \\ nil),
    do: GenServer.call(server(agent), {:compact, instructions})

  @doc "Blocks until the agent is idle."
  def await(agent, timeout \\ :infinity), do: GenServer.call(server(agent), :await, timeout)

  @doc "A snapshot of the agent's observable state."
  def snapshot(agent), do: GenServer.call(server(agent), :snapshot)

  @doc """
  Subscribes the calling process to the agent's events. Subscriptions are
  keyed by agent id, not pid, so they survive agent restarts.
  """
  def subscribe(id) when is_binary(id) do
    key = {:events, id}

    if Registry.values(Pie.PubSub, key, self()) == [],
      do: {:ok, _} = Registry.register(Pie.PubSub, key, nil)

    :ok
  end

  def unsubscribe(id), do: Registry.unregister(Pie.PubSub, {:events, id})

  defp server(id) when is_binary(id), do: via(id)
  defp server(pid) when is_pid(pid), do: pid

  defp to_messages(text) when is_binary(text), do: [UserMessage.new(text)]
  defp to_messages(%UserMessage{} = message), do: [message]
  defp to_messages(messages) when is_list(messages), do: messages

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    session = Keyword.fetch!(opts, :session)

    state = %__MODULE__{
      id: id,
      model: Keyword.fetch!(opts, :model),
      session: session,
      system_prompt: Pie.Extension.system_prompt(id, Keyword.get(opts, :system_prompt, "")),
      tools: Keyword.get(opts, :tools, []) ++ Pie.Extension.tools(id),
      messages: Pie.Session.context(session),
      stream_opts: Keyword.get(opts, :stream_opts, []),
      max_concurrency: Keyword.get(opts, :max_concurrency, 4),
      transform_context: Keyword.get(opts, :transform_context, &Function.identity/1),
      compaction:
        Map.merge(Pie.Compaction.defaults(), Map.new(Keyword.get(opts, :compaction, [])))
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, messages}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, messages)}

  def handle_call({:prompt, _}, _from, s), do: {:reply, {:error, s.status}, s}

  def handle_call({:enqueue, _kind, messages}, _from, %{status: :idle} = s),
    do: {:reply, {:ok, :started}, start_run(s, messages)}

  def handle_call({:enqueue, kind, messages}, _from, s),
    do: {:reply, {:ok, :queued}, Map.update!(s, kind, &(&1 ++ messages))}

  def handle_call({:dequeue, run_id, kind}, _from, %{run: %{id: run_id}} = s),
    do: {:reply, Map.fetch!(s, kind), Map.put(s, kind, [])}

  def handle_call({:dequeue, _stale_run, _kind}, _from, s), do: {:reply, [], s}

  def handle_call(:abort, _from, %{run: %{kind: :loop} = run} = s) do
    send(run.task.pid, {:abort, run.id})
    {:reply, :ok, %{s | steering: [], follow_up: []}}
  end

  def handle_call(:abort, _from, %{run: %{kind: :compaction} = run} = s) do
    Task.shutdown(run.task, :brutal_kill)
    s = broadcast(s, {:compaction_end, {:error, :aborted}})
    {:reply, :ok, %{s | steering: [], follow_up: []} |> idle() |> drain()}
  end

  def handle_call(:abort, _from, s), do: {:reply, :ok, s}

  def handle_call({:compact, instructions}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_compaction(s, :manual, instructions)}

  def handle_call({:compact, _}, _from, s), do: {:reply, {:error, s.status}, s}

  def handle_call(:await, _from, %{status: :idle} = s), do: {:reply, :ok, s}
  def handle_call(:await, from, s), do: {:noreply, %{s | waiters: [from | s.waiters]}}

  def handle_call(:snapshot, _from, s) do
    snapshot =
      Map.take(s, [
        :id,
        :model,
        :status,
        :messages,
        :stream_message,
        :pending_tools,
        :steering,
        :follow_up,
        :error
      ])

    {:reply, snapshot, s}
  end

  @impl true
  def handle_info({:run_event, run_id, event}, %{run: %{id: run_id}} = s) do
    {:noreply, s |> apply_event(event) |> broadcast(event)}
  end

  def handle_info({:run_event, _stale_run, _event}, s), do: {:noreply, s}

  def handle_info({ref, result}, %{run: %{task: %{ref: ref}} = run} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, completed(run.kind, result, s)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{task: %{ref: ref}} = run} = s) do
    s =
      if run.kind == :compaction,
        do: broadcast(s, {:compaction_end, {:error, reason}}),
        else: broadcast(s, {:run_crashed, reason})

    {:noreply, s |> idle() |> Map.put(:error, Exception.format_exit(reason)) |> drain()}
  end

  # Exits of linked run tasks; the reply or :DOWN above carries the outcome.
  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, %{run: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  ## Runs

  defp start_run(s, prompts) do
    run_id = make_ref()
    agent = self()
    id = s.id

    config = %Loop.Config{
      model: s.model,
      system_prompt: s.system_prompt,
      tools: s.tools,
      stream_opts: s.stream_opts,
      max_concurrency: s.max_concurrency,
      transform_context: s.transform_context,
      signal: run_id,
      parent: agent,
      emit: &send(agent, {:run_event, run_id, &1}),
      steering: fn -> GenServer.call(agent, {:dequeue, run_id, :steering}, :infinity) end,
      follow_up: fn -> GenServer.call(agent, {:dequeue, run_id, :follow_up}, :infinity) end,
      before_tool_call: &Pie.Extension.before_tool_call(id, &1)
    }

    history = s.messages
    task = Task.Supervisor.async(Pie.TaskSupervisor, fn -> Loop.run(prompts, history, config) end)
    %{s | status: :running, run: %{id: run_id, kind: :loop, task: task}, error: nil}
  end

  defp completed(:loop, _new_messages, s) do
    s = idle(s)

    if Pie.Compaction.due?(s.messages, s.model, s.compaction),
      do: start_compaction(s, :threshold, nil),
      else: drain(s)
  end

  defp completed(:compaction, {:ok, compaction}, s) do
    Pie.Session.append_compaction(s.session, compaction)

    %{s | messages: Pie.Session.context(s.session)}
    |> broadcast({:compaction_end, {:ok, compaction}})
    |> idle()
    |> drain()
  end

  defp completed(:compaction, noop_or_error, s) do
    s |> broadcast({:compaction_end, noop_or_error}) |> idle() |> drain()
  end

  # Compaction is an LLM call: it runs in a task so the agent stays responsive.
  defp start_compaction(s, reason, instructions) do
    s = broadcast(s, {:compaction_start, reason})
    path = Pie.Session.path(s.session)
    %{model: model, compaction: settings, stream_opts: opts} = s

    task =
      Task.Supervisor.async(Pie.TaskSupervisor, fn ->
        Pie.Compaction.run(path, model, settings, opts, instructions)
      end)

    %{s | status: :compacting, run: %{id: make_ref(), kind: :compaction, task: task}}
  end

  defp idle(s),
    do: %{s | status: :idle, run: nil, stream_message: nil, pending_tools: MapSet.new()}

  # Messages queued after the loop last asked for them start the next run.
  defp drain(%{steering: [], follow_up: []} = s) do
    Enum.each(s.waiters, &GenServer.reply(&1, :ok))
    %{s | waiters: []}
  end

  defp drain(s), do: start_run(%{s | steering: [], follow_up: []}, s.steering ++ s.follow_up)

  defp apply_event(s, {:message_start, %AssistantMessage{} = partial}),
    do: %{s | stream_message: partial}

  defp apply_event(s, {:message_update, event}), do: %{s | stream_message: Pie.AI.partial(event)}

  defp apply_event(s, {:message_end, message}) do
    Pie.Session.append_message(s.session, message)
    %{s | messages: s.messages ++ [message], stream_message: nil}
  end

  defp apply_event(s, {:tool_execution_start, call}),
    do: update_in(s.pending_tools, &MapSet.put(&1, call.id))

  defp apply_event(s, {:tool_execution_end, call, _}),
    do: update_in(s.pending_tools, &MapSet.delete(&1, call.id))

  defp apply_event(s, _event), do: s

  # Every event goes to subscribers and to :telemetry (see Pie.Telemetry).
  defp broadcast(s, event) do
    Registry.dispatch(Pie.PubSub, {:events, s.id}, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:pie_event, s.id, event})
    end)

    %{s | timers: Pie.Telemetry.handle(s.timers, s.id, event)}
  end
end
