defmodule Pie.Agent.LoopTest do
  use ExUnit.Case, async: true

  alias Pie.AI.{AssistantMessage, Message, Model, ToolResultMessage, UserMessage}
  alias Pie.AI.Providers.Faux
  alias Pie.Agent.Loop
  alias Pie.Agent.Loop.Config

  defp model(responses, options),
    do: Model.new(:faux, "faux", options: Map.put(options, :responder, Faux.sequence(responses)))

  defp config(responses, opts \\ []) do
    test = self()
    {options, opts} = Keyword.pop(opts, :model_options, %{})
    struct!(Config, [model: model(responses, options), emit: &send(test, {:event, &1})] ++ opts)
  end

  defp tool(name, fun, opts \\ []) do
    struct!(
      Pie.Tool,
      [
        name: name,
        description: "test tool",
        parameters: %{type: "object", properties: %{}, required: []},
        execute: fun
      ] ++ opts
    )
  end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp names(events), do: Enum.map(events, &if(is_atom(&1), do: &1, else: elem(&1, 0)))

  test "a plain reply is one turn with an observable lifecycle" do
    new = Loop.run([UserMessage.new("hi")], [], config(["Hello there"]))

    assert [%UserMessage{}, %AssistantMessage{stop_reason: :stop} = reply] = new
    assert Message.text(reply) == "Hello there"

    assert names(events()) == [
             :agent_start,
             :turn_start,
             :message_start,
             :message_end,
             :message_start,
             :message_update,
             :message_update,
             :message_update,
             :message_update,
             :message_end,
             :turn_end,
             :agent_end
           ]
  end

  test "tool calls run, their results go back to the model, and the loop continues" do
    echo = tool("echo", fn args, _ -> {:ok, "echo: #{args["text"]}"} end)

    responses = [
      [{:text, "Calling"}, {:tool_call, "echo", %{"text" => "ping"}}],
      fn context ->
        assert %ToolResultMessage{content: [%{text: "echo: ping"}]} = List.last(context.messages)
        "Got it"
      end
    ]

    new = Loop.run([UserMessage.new("go")], [], config(responses, tools: [echo]))

    assert [
             %UserMessage{},
             %AssistantMessage{stop_reason: :tool_use},
             %ToolResultMessage{is_error: false},
             %AssistantMessage{stop_reason: :stop}
           ] = new

    events = events()
    assert Enum.count(events, &(&1 == :turn_start)) == 2

    assert [{:tool_execution_start, %{name: "echo"}}] =
             Enum.filter(events, &match?({:tool_execution_start, _}, &1))

    assert [{:tool_execution_end, _, %{is_error: false}}] =
             Enum.filter(events, &match?({:tool_execution_end, _, _}, &1))
  end

  @tag :capture_log
  test "every tool call gets exactly one result, whatever goes wrong" do
    tools = [
      tool("boom", fn _, _ -> raise "kaboom" end),
      tool("slow", fn _, _ -> Process.sleep(5_000) end, timeout: 50),
      tool("typed", fn _, _ -> {:ok, "fine"} end,
        parameters: %{type: "object", properties: %{n: %{type: "integer"}}, required: ["n"]}
      ),
      tool("guarded", fn _, _ -> {:ok, "never runs"} end)
    ]

    calls = [
      {:tool_call, "boom", %{}},
      {:tool_call, "slow", %{}},
      {:tool_call, "typed", %{"n" => "one"}},
      {:tool_call, "missing", %{}},
      {:tool_call, "guarded", %{}}
    ]

    gate = fn call -> if call.name == "guarded", do: {:block, "not allowed"}, else: :ok end

    new =
      Loop.run(
        [UserMessage.new("go")],
        [],
        config([calls, "done"], tools: tools, before_tool_call: gate)
      )

    results = Enum.filter(new, &match?(%ToolResultMessage{}, &1))
    assert Enum.map(results, & &1.tool_name) == ["boom", "slow", "typed", "missing", "guarded"]
    assert Enum.all?(results, & &1.is_error)

    [boom, slow, typed, missing, guarded] = Enum.map(results, &Message.text/1)
    assert boom =~ "Tool crashed" and boom =~ "kaboom"
    assert slow == "Tool timed out"
    assert typed =~ ~s("n" must be integer)
    assert missing =~ "not found"
    assert guarded == "Blocked: not allowed"
    refute_received {:EXIT, _, _}
  end

  test "parallel tools run concurrently; other tools act as barriers" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    probe = fn name ->
      fn _, _ ->
        Agent.update(log, &[{:start, name} | &1])
        Process.sleep(50)
        Agent.update(log, &[{:stop, name} | &1])
        {:ok, name}
      end
    end

    tools = [
      tool("r1", probe.("r1"), parallel: true),
      tool("r2", probe.("r2"), parallel: true),
      tool("w", probe.("w")),
      tool("r3", probe.("r3"), parallel: true)
    ]

    calls = for name <- ["r1", "r2", "w", "r3"], do: {:tool_call, name, %{}}
    Loop.run([UserMessage.new("go")], [], config([calls, "done"], tools: tools))

    assert log |> Agent.get(& &1) |> Enum.reverse() == [
             {:start, "r1"},
             {:start, "r2"},
             {:stop, "r1"},
             {:stop, "r2"},
             {:start, "w"},
             {:stop, "w"},
             {:start, "r3"},
             {:stop, "r3"}
           ]
  end

  test "aborting during tools kills running tools and skips queued ones" do
    test = self()

    tools = [
      tool("hang", fn _, _ ->
        send(test, {:tool_pid, self()})
        Process.sleep(:infinity)
      end),
      tool("next", fn _, _ -> {:ok, "never"} end)
    ]

    signal = make_ref()
    calls = [{:tool_call, "hang", %{}}, {:tool_call, "next", %{}}]
    cfg = config([calls], tools: tools, signal: signal)
    loop = Task.async(fn -> Loop.run([UserMessage.new("go")], [], cfg) end)

    assert_receive {:tool_pid, tool_pid}
    send(loop.pid, {:abort, signal})

    assert [_, _, %ToolResultMessage{} = hang, %ToolResultMessage{} = skipped] = Task.await(loop)

    assert {Message.text(hang), Message.text(skipped)} ==
             {"Aborted", "Skipped: the run was aborted"}

    refute Process.alive?(tool_pid)
  end

  test "aborting mid-stream ends the run with the partial reply" do
    signal = make_ref()
    cfg = config(["one two three four five six"], signal: signal, model_options: %{delay: 20})
    loop = Task.async(fn -> Loop.run([UserMessage.new("go")], [], cfg) end)
    assert_receive {:event, {:message_update, {:text_delta, _, _, _}}}, 1_000
    send(loop.pid, {:abort, signal})

    assert [%UserMessage{}, %AssistantMessage{stop_reason: :aborted} = partial] = Task.await(loop)
    assert Message.text(partial) =~ "one"
  end

  test "steering messages start the next turn; follow-ups run when the agent would stop" do
    {:ok, queue} =
      Agent.start_link(fn ->
        %{steering: [[UserMessage.new("steer")]], follow_up: [[UserMessage.new("more")]]}
      end)

    take = fn kind ->
      fn ->
        Agent.get_and_update(queue, fn q ->
          {List.first(q[kind]) || [], Map.update!(q, kind, &Enum.drop(&1, 1))}
        end)
      end
    end

    new =
      Loop.run(
        [UserMessage.new("start")],
        [],
        config(["first", "after steer", "after follow-up"],
          steering: take.(:steering),
          follow_up: take.(:follow_up)
        )
      )

    assert Enum.map(new, &Message.text/1) == [
             "start",
             "first",
             "steer",
             "after steer",
             "more",
             "after follow-up"
           ]
  end
end
