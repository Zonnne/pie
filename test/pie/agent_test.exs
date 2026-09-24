defmodule Pie.AgentTest do
  use ExUnit.Case, async: true

  alias Pie.AI.{AssistantMessage, Message, Model, UserMessage}
  alias Pie.AI.Providers.Faux

  defp faux(responses, options \\ %{}),
    do: Model.new(:faux, "faux", options: Map.put(options, :responder, Faux.sequence(responses)))

  defp start(opts) do
    {:ok, id} = Pie.start_agent(opts)
    on_exit(fn -> Pie.stop_agent(id) end)
    :ok = Pie.subscribe(id)
    id
  end

  defp tool(name, fun) do
    %Pie.Tool{name: name, description: "t", parameters: %{type: "object"}, execute: fun}
  end

  defp collect_until(id, match, acc \\ []) do
    receive do
      {:pie_event, ^id, event} ->
        if match.(event),
          do: Enum.reverse([event | acc]),
          else: collect_until(id, match, [event | acc])
    after
      2_000 -> flunk("timed out; got #{inspect(Enum.map(acc, &elem(&1, 0)))}")
    end
  end

  test "events are broadcast in order, after the agent's state is updated" do
    id = start(model: faux(["Hi!"]))
    :ok = Pie.prompt(id, "hello")

    events = collect_until(id, &match?({:message_end, %AssistantMessage{}}, &1))
    assert [:agent_start, :turn_start | _] = events
    %{messages: messages} = Pie.snapshot(id)
    assert [%UserMessage{}, %AssistantMessage{} = reply] = messages
    assert Message.text(reply) == "Hi!"

    assert [{:turn_end, _, []}, {:agent_end, [_, _]}] =
             collect_until(id, &match?({:agent_end, _}, &1))

    assert :ok = Pie.await(id)
    assert %{status: :idle} = Pie.snapshot(id)
  end

  test "prompting while busy is refused; steering is queued for the next turn" do
    test = self()

    slow =
      tool("slow", fn _, _ ->
        send(test, :tool_running)
        Process.sleep(100)
        {:ok, "done"}
      end)

    responses = [
      [{:tool_call, "slow", %{}}],
      fn context ->
        assert %UserMessage{} = steer = List.last(context.messages)
        assert Message.text(steer) == "also do this"
        "ok, both"
      end
    ]

    id = start(model: faux(responses), tools: [slow])
    :ok = Pie.prompt(id, "go")
    assert_receive :tool_running
    assert {:error, :running} = Pie.prompt(id, "again")
    assert {:ok, :queued} = Pie.steer(id, "also do this")
    Pie.await(id)

    assert Enum.map(Pie.snapshot(id).messages, &Message.text/1) ==
             ["go", "", "done", "also do this", "ok, both"]
  end

  test "abort keeps the partial reply and clears queued messages" do
    id = start(model: faux(["a b c d e f g h i j"], %{delay: 30}))
    :ok = Pie.prompt(id, "go")
    collect_until(id, &match?({:message_update, {:text_delta, _, _, _}}, &1))
    {:ok, :queued} = Pie.follow_up(id, "later")
    :ok = Pie.abort(id)
    Pie.await(id)

    assert %{
             status: :idle,
             follow_up: [],
             messages: [_, %AssistantMessage{stop_reason: :aborted} = partial]
           } =
             Pie.snapshot(id)

    assert Message.text(partial) =~ "a"
  end

  @tag :capture_log
  test "a crashing run is reported and the agent stays usable" do
    boom = fn _ -> raise "projection bug" end
    id = start(model: faux(["never", "fine"]), transform_context: boom)
    :ok = Pie.prompt(id, "go")

    assert [_ | _] = collect_until(id, &match?({:run_crashed, _}, &1))
    Pie.await(id)
    assert %{status: :idle, error: error} = Pie.snapshot(id)
    assert error =~ "projection bug"
  end

  test "a run dies with its agent, tools included" do
    test = self()
    hang = tool("hang", fn _, _ -> send(test, {:tool, self()}) && Process.sleep(:infinity) end)
    id = start(model: faux([[{:tool_call, "hang", %{}}]]), tools: [hang])
    :ok = Pie.prompt(id, "go")
    assert_receive {:tool, tool_pid}
    ref = Process.monitor(tool_pid)

    Process.exit(GenServer.whereis(Pie.Agent.via(id)), :kill)
    assert_receive {:DOWN, ^ref, :process, ^tool_pid, _}, 1_000
  end

  test "subscriptions survive an agent restart" do
    id = start(model: faux(["first", "second"]))
    pid = GenServer.whereis(Pie.Agent.via(id))
    Process.exit(pid, :kill)

    restarted = wait_for_restart(id, pid)
    assert restarted != pid
    :ok = Pie.prompt(id, "hello again")
    assert [_ | _] = collect_until(id, &match?({:agent_end, _}, &1))
  end

  test "invalid options fail at start with a clear message" do
    error =
      assert_raise NimbleOptions.ValidationError, fn ->
        Pie.start_agent(model: faux([]), tols: [])
      end

    assert Exception.message(error) =~ "unknown options [:tols]"

    assert_raise NimbleOptions.ValidationError, ~r/max_concurrency/, fn ->
      Pie.start_agent(model: faux([]), max_concurrency: 0)
    end

    assert_raise NimbleOptions.ValidationError, ~r/required :model/, fn -> Pie.start_agent([]) end
  end

  test "events render as JSON" do
    id = start(model: faux([[{:text, "hi"}, {:tool_call, "missing", %{"a" => 1}}], "ok"]))
    :ok = Pie.prompt(id, "go")
    events = collect_until(id, &match?({:agent_end, _}, &1))

    json =
      Enum.map(events, &(&1 |> Pie.Agent.Event.to_json() |> JSON.encode!() |> JSON.decode!()))

    types = Enum.map(json, & &1["type"])
    assert "tool_execution_end" in types and List.last(types) == "agent_end"

    assert %{"type" => "message_update", "event" => %{"delta" => "hi"}} =
             Enum.find(json, &(&1["event"]["type"] == "text_delta"))
  end

  defp wait_for_restart(id, old, tries \\ 50) do
    case GenServer.whereis(Pie.Agent.via(id)) do
      pid when is_pid(pid) and pid != old -> pid
      _ when tries > 0 -> Process.sleep(10) && wait_for_restart(id, old, tries - 1)
      _ -> flunk("agent was not restarted")
    end
  end
end
