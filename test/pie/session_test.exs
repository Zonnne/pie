defmodule Pie.SessionTest do
  use ExUnit.Case, async: true

  alias Pie.AI.{AssistantMessage, Message, Model, Text, ToolCall, ToolResultMessage, UserMessage}
  alias Pie.AI.Providers.Faux
  alias Pie.Session

  @moduletag :tmp_dir

  defp session(path), do: start_supervised!({Session, path: path, cwd: "/work"}, id: make_ref())

  test "entries round-trip through the JSONL file", %{tmp_dir: dir} do
    path = Path.join(dir, "s.jsonl")
    s = session(path)

    messages = [
      UserMessage.new("hi"),
      %AssistantMessage{
        content: [
          %Text{text: "reading"},
          %ToolCall{id: "t1", name: "read", arguments: %{"path" => "x"}}
        ],
        provider: "faux",
        model: "m",
        stop_reason: :tool_use,
        timestamp: 1
      },
      %ToolResultMessage{
        tool_call_id: "t1",
        tool_name: "read",
        content: [%Text{text: "data"}],
        timestamp: 2
      }
    ]

    Enum.each(messages, &Session.append_message(s, &1))
    assert Session.context(s) == messages

    [header | lines] =
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert %{"type" => "session", "version" => 1, "cwd" => "/work"} = header
    assert [nil | _] = Enum.map(lines, & &1["parentId"])

    reloaded = session(path)
    assert Session.context(reloaded) == messages
    assert Session.info(reloaded).id == header["id"]
  end

  test "the file is created lazily, on the first append", %{tmp_dir: dir} do
    path = Path.join(dir, "nested/lazy.jsonl")
    s = session(path)
    refute File.exists?(path)
    Session.append_message(s, UserMessage.new("now"))
    assert File.exists?(path)
  end

  test "a torn last line loses one entry, not the session", %{tmp_dir: dir} do
    path = Path.join(dir, "torn.jsonl")
    s = session(path)
    Session.append_message(s, UserMessage.new("kept"))
    File.write!(path, ~s({"type":"message","id":"zz","mess), [:append])

    assert [%UserMessage{} = kept] = Session.context(session(path))
    assert Message.text(kept) == "kept"
  end

  test "branching moves the leaf; the context follows, history stays", %{tmp_dir: dir} do
    s = session(Path.join(dir, "tree.jsonl"))
    a = Session.append_message(s, UserMessage.new("a"))
    _b = Session.append_message(s, UserMessage.new("b"))
    :ok = Session.branch(s, a)
    Session.append_message(s, UserMessage.new("c"))

    assert Enum.map(Session.context(s), &Message.text/1) == ["a", "c"]
    assert length(Session.entries(s)) == 3
    assert {:error, :not_found} = Session.branch(s, "nope")
  end

  describe "agents on sessions" do
    defp start_agent(path, responses) do
      model = Model.new(:faux, "faux", options: %{responder: Faux.sequence(responses)})
      {:ok, id} = Pie.start_agent(model: model, session_path: path, cwd: "/work")
      on_exit(fn -> Pie.stop_agent(id) end)
      id
    end

    test "a message is persisted before it is broadcast", %{tmp_dir: dir} do
      id = start_agent(Path.join(dir, "a.jsonl"), ["reply"])
      Pie.subscribe(id)
      :ok = Pie.prompt(id, "hello")

      assert_receive {:pie_event, ^id, {:message_end, %AssistantMessage{} = reply}}
      assert List.last(Session.context(Pie.session(id))) == reply
    end

    test "a crashed agent re-hydrates from its session", %{tmp_dir: dir} do
      id = start_agent(Path.join(dir, "b.jsonl"), ["one", "two"])
      :ok = Pie.prompt(id, "first")
      Pie.await(id)
      before = Pie.snapshot(id).messages

      agent = GenServer.whereis(Pie.Agent.via(id))
      Process.exit(agent, :kill)
      assert eventually(fn -> GenServer.whereis(Pie.Agent.via(id)) not in [nil, agent] end)
      assert Pie.snapshot(id).messages == before
    end

    test "a crashed session reloads from disk and the agent restarts after it", %{tmp_dir: dir} do
      id = start_agent(Path.join(dir, "c.jsonl"), ["one", "two"])
      :ok = Pie.prompt(id, "first")
      Pie.await(id)
      before = Pie.snapshot(id).messages
      agent = GenServer.whereis(Pie.Agent.via(id))

      Process.exit(GenServer.whereis(Pie.session(id)), :kill)
      assert eventually(fn -> GenServer.whereis(Pie.Agent.via(id)) not in [nil, agent] end)
      assert Pie.snapshot(id).messages == before

      :ok = Pie.prompt(id, "second")
      Pie.await(id)

      assert Enum.map(Pie.snapshot(id).messages, &Message.text/1) == [
               "first",
               "one",
               "second",
               "two"
             ]
    end

    test "a new agent resumes a session file", %{tmp_dir: dir} do
      path = Path.join(dir, "d.jsonl")
      first = start_agent(path, ["remembered"])
      :ok = Pie.prompt(first, "remember this")
      Pie.await(first)
      Pie.stop_agent(first)

      second =
        start_agent(path, [
          fn context ->
            assert Enum.map(context.messages, &Message.text/1) == [
                     "remember this",
                     "remembered",
                     "and now?"
                   ]

            "yes"
          end
        ])

      :ok = Pie.prompt(second, "and now?")
      Pie.await(second)
      assert Message.text(List.last(Pie.snapshot(second).messages)) == "yes"
    end
  end

  test "sessions are stored per working directory" do
    assert Session.dir("/home/me/proj") == Path.join([Pie.home(), "sessions", "--home-me-proj--"])

    assert Session.new_path("/home/me/proj") =~
             ~r"--home-me-proj--/\d{8}T\d{6}Z_[0-9a-f]{8}\.jsonl$"
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
