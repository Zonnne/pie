defmodule Pie.CLITest do
  # Not async: these tests share the session directory for the cwd.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pie.CLI

  defp run(args, input \\ "") do
    parent = self()
    output = capture_io(input, fn -> send(parent, {:status, CLI.run(args)}) end)
    assert_received {:status, status}
    {status, output}
  end

  test "print mode prints the final answer" do
    assert {0, "You said: hello there\n"} = run(~w(--provider faux --no-session -p hello there))
  end

  test "json mode prints every lifecycle event as a JSON line" do
    {0, output} = run(~w(--provider faux --no-session --mode json hi))
    events = output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    types = Enum.map(events, & &1["type"])

    assert hd(types) == "agent_start" and List.last(types) == "agent_end"
    assert "message_update" in types

    assert %{"message" => %{"role" => "assistant"}} =
             Enum.find(Enum.reverse(events), &(&1["type"] == "message_end"))
  end

  test "interactive mode renders replies, runs commands, and exits at EOF after finishing" do
    {0, output} = run(~w(--provider faux --no-session), "first message\n/session\n/nope\n")

    assert output =~ "pie · faux/echo · in-memory session"
    assert output =~ "You said: first message"
    assert output =~ "entries:"
    assert output =~ "unknown command /nope"
  end

  test "--continue resumes the latest session for this directory" do
    {0, _} = run(~w(--provider faux -p one))
    path = Pie.Session.latest(File.cwd!())
    {0, _} = run(~w(--provider faux -c -p two))

    assert Pie.Session.latest(File.cwd!()) == path
    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 5
  end

  @tag :tmp_dir
  test "end to end: the CLI drives a real HTTP model through a tool call", %{tmp_dir: dir} do
    test = self()

    # A stateful fake Anthropic endpoint: first a bash tool call, then an answer
    # that quotes the tool result it was sent.
    url =
      Pie.Test.SSEServer.start(fn body ->
        request = JSON.decode!(body)
        send(test, {:request, request})

        case request["messages"] |> List.last() |> Map.fetch!("content") |> hd() do
          %{"type" => "tool_result", "content" => [%{"text" => output}]} ->
            {200,
             sse_reply(
               [text_block(0, "The command printed: " <> String.trim(output))],
               "end_turn"
             )}

          _first_turn ->
            {200,
             sse_reply(
               [tool_block(0, "toolu_1", "bash", %{"command" => "echo pie-e2e"})],
               "tool_use"
             )}
        end
      end)

    System.put_env("ANTHROPIC_BASE_URL", url)
    System.put_env("ANTHROPIC_API_KEY", "test-key")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_BASE_URL")
      System.delete_env("ANTHROPIC_API_KEY")
    end)

    File.cd!(dir, fn ->
      assert {0, "The command printed: pie-e2e\n"} =
               run(~w(--model test-model --no-session -p run it))
    end)

    assert_received {:request, first}
    assert first["model"] == "test-model"
    assert Enum.map(first["tools"], & &1["name"]) == ["read", "bash", "edit", "write"]
    assert [%{"text" => system}] = first["system"]
    assert system =~ "Current working directory: #{dir}"
  end

  defp sse_reply(blocks, stop_reason) do
    Pie.Test.SSEServer.sse(
      [%{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}}] ++
        List.flatten(blocks) ++
        [
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => stop_reason},
            "usage" => %{"output_tokens" => 5}
          },
          %{"type" => "message_stop"}
        ]
    )
  end

  defp text_block(i, text) do
    [
      %{
        "type" => "content_block_start",
        "index" => i,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => i,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => i}
    ]
  end

  defp tool_block(i, id, name, input) do
    [
      %{
        "type" => "content_block_start",
        "index" => i,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
      },
      %{
        "type" => "content_block_delta",
        "index" => i,
        "delta" => %{"type" => "input_json_delta", "partial_json" => JSON.encode!(input)}
      },
      %{"type" => "content_block_stop", "index" => i}
    ]
  end

  test "configuration errors exit with status 2" do
    System.delete_env("PIE_MODEL")
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        send(parent, {:status, CLI.run(~w(--provider anthropic -p hi))})
      end)

    assert_received {:status, 2}
    assert stderr =~ "No model configured"

    assert capture_io(:stderr, fn -> assert {2, _} = run(~w(--bogus)) end) =~ "Unknown option"
    assert {0, usage} = run(~w(--help))
    assert usage =~ "Usage: pie"
  end
end
