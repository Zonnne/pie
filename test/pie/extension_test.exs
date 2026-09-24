defmodule Pie.ExtensionTest do
  use ExUnit.Case, async: true

  alias Pie.AI.{Message, Model, ToolResultMessage}
  alias Pie.AI.Providers.Faux

  defmodule Clock do
    use Pie.Extension

    @impl true
    def tools(_state) do
      [
        %Pie.Tool{
          name: "now",
          description: "The time",
          parameters: %{type: "object"},
          execute: fn _, _ -> {:ok, "noon"} end
        }
      ]
    end

    @impl true
    def system_prompt(prompt, _state), do: prompt <> "\nIt is always noon."
  end

  defmodule Gate do
    use Pie.Extension

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :deny)}

    @impl true
    def before_tool_call(%{name: name}, deny) do
      cond do
        name == "crash" -> raise "gate bug"
        name in deny -> {:block, "#{name} is not allowed"}
        true -> :ok
      end
    end
  end

  defmodule Recorder do
    use Pie.Extension

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test)}

    @impl true
    def handle_event(:turn_start, _test), do: raise("observer bug")
    def handle_event(event, test), do: send(test, {:observed, event}) && {:ok, test}
  end

  defp start(responses, extensions, tools \\ []) do
    model = Model.new(:faux, "faux", options: %{responder: Faux.sequence(responses)})

    {:ok, id} =
      Pie.start_agent(model: model, extensions: extensions, tools: tools, system_prompt: "Base.")

    on_exit(fn -> Pie.stop_agent(id) end)
    id
  end

  defp tool(name),
    do: %Pie.Tool{
      name: name,
      description: "t",
      parameters: %{type: "object"},
      execute: fn _, _ -> {:ok, "ran"} end
    }

  defp results(id),
    do:
      for(
        %ToolResultMessage{} = r <- Pie.snapshot(id).messages,
        do: {r.tool_name, Message.text(r)}
      )

  test "extensions contribute tools and amend the system prompt" do
    responses = [
      fn context ->
        assert context.system_prompt == "Base.\nIt is always noon."
        assert "now" in Enum.map(context.tools, & &1.name)
        [{:tool_call, "now", %{}}]
      end,
      "It is noon."
    ]

    id = start(responses, [Clock])
    :ok = Pie.prompt(id, "time?")
    Pie.await(id)
    assert results(id) == [{"now", "noon"}]
  end

  @tag :capture_log
  test "gates block tool calls, and a failing gate fails closed" do
    calls = [{:tool_call, "rm", %{}}, {:tool_call, "ls", %{}}, {:tool_call, "crash", %{}}]
    id = start([calls, "ok"], [{Gate, deny: ["rm"]}], [tool("rm"), tool("ls"), tool("crash")])
    :ok = Pie.prompt(id, "go")
    Pie.await(id)

    assert [
             {"rm", "Blocked: rm is not allowed"},
             {"ls", "ran"},
             {"crash", "Blocked: extension Pie.ExtensionTest.Gate is unavailable"}
           ] = results(id)
  end

  @tag :capture_log
  test "a crashing observer is restarted without disturbing the agent" do
    id = start(["one", "two"], [{Recorder, test: self()}])
    agent = GenServer.whereis(Pie.Agent.via(id))

    :ok = Pie.prompt(id, "go")
    Pie.await(id)
    :ok = Pie.prompt(id, "again")
    Pie.await(id)

    assert GenServer.whereis(Pie.Agent.via(id)) == agent
    assert Enum.map(Pie.snapshot(id).messages, &Message.text/1) == ["go", "one", "again", "two"]
    # Observers run asynchronously; give the restarted one time to catch up.
    assert_receive {:observed, :agent_start}
  end

  @tag :tmp_dir
  test "the protected-paths example loads from a file and blocks writes", %{tmp_dir: dir} do
    # nil when an earlier (repeated) run already loaded the file.
    module =
      case Code.require_file("examples/extensions/protected_paths.exs") do
        [{module, _}] -> module
        nil -> ProtectedPaths
      end

    assert Pie.Extension.extension?(module)
    refute Pie.Extension.extension?(Enum)

    write = Pie.Tools.Write.tool(dir)
    calls = [{:tool_call, "write", %{"path" => ".env", "content" => "SECRET=1"}}]
    id = start([calls, "ok"], [module], [write])
    :ok = Pie.prompt(id, "go")
    Pie.await(id)

    assert [{"write", "Blocked: .env is protected" <> _}] = results(id)
    refute File.exists?(Path.join(dir, ".env"))
  end
end
