defmodule Pie.CompactionTest do
  use ExUnit.Case, async: true

  alias Pie.AI.{
    AssistantMessage,
    Codec,
    Message,
    Model,
    Text,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  alias Pie.Compaction
  alias Pie.Session.Context, as: Projection

  defp entry(id, message),
    do: %{"type" => "message", "id" => id, "message" => Codec.encode(message)}

  defp user(text), do: UserMessage.new(text)

  defp reply(text, usage \\ %Usage{}),
    do: %AssistantMessage{content: [%Text{text: text}], stop_reason: :stop, usage: usage}

  describe "projection" do
    test "the latest compaction replaces everything before its first kept entry" do
      path = [
        entry("1", user("old question")),
        entry("2", reply("old answer")),
        entry("3", user("recent question")),
        entry("4", reply("recent answer")),
        %{
          "type" => "compaction",
          "id" => "5",
          "summary" => "S",
          "firstKeptEntryId" => "3",
          "timestamp" => "2026-01-01T00:00:00Z"
        },
        entry("6", user("after"))
      ]

      assert [summary | rest] = Projection.messages(path)
      assert Message.text(summary) =~ "<summary>\nS\n</summary>"
      assert Enum.map(rest, &Message.text/1) == ["recent question", "recent answer", "after"]
    end
  end

  describe "planning" do
    test "the cut keeps recent messages and never separates a tool result from its call" do
      call = %ToolCall{id: "c", name: "bash", arguments: %{}}
      big = String.duplicate("x", 400)

      path = [
        entry("1", user(big)),
        entry("2", %AssistantMessage{content: [call], stop_reason: :tool_use}),
        entry("3", %ToolResultMessage{
          tool_call_id: "c",
          tool_name: "bash",
          content: [%Text{text: big}]
        }),
        entry("4", reply("done"))
      ]

      responder = fn ctx ->
        prompt = ctx.messages |> hd() |> Message.text()
        assert prompt =~ "[User]: xxx"
        refute prompt =~ "[Tool result]"
        "SUMMARY"
      end

      model = Model.new(:faux, "faux", options: %{responder: responder})

      # ~101 tokens are enough to reach into the tool result, so the cut moves
      # back to the tool call that produced it.
      assert {:ok, %{summary: "SUMMARY", first_kept_id: "2"}} =
               Compaction.run(path, model, %{keep_recent_tokens: 101})

      assert :noop = Compaction.run(path, model, %{keep_recent_tokens: 10_000})
    end

    test "context tokens are the last reported usage plus estimates after it" do
      messages = [
        user("q"),
        reply("a", %Usage{input: 1000, output: 50}),
        user(String.duplicate("y", 400))
      ]

      assert Compaction.context_tokens(messages) == 1150

      assert Compaction.due?(messages, Model.new(:faux, "f", context_window: 1200), %{
               enabled: true,
               reserve_tokens: 100
             })

      refute Compaction.due?(messages, Model.new(:faux, "f", context_window: 2000), %{
               enabled: true,
               reserve_tokens: 100
             })
    end
  end

  describe "agents" do
    # Answers normal turns in sequence and summarization requests with "SUMMARY n".
    defp responder(test) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fn context ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        if context.system_prompt =~ "summarize" do
          send(test, {:summarizer_saw, context.messages |> hd() |> Message.text()})
          "SUMMARY #{n}"
        else
          send(test, {:model_saw, Enum.map(context.messages, &Message.text/1)})
          String.duplicate("word ", 100)
        end
      end
    end

    defp start(opts) do
      model =
        Model.new(
          :faux,
          "faux",
          Keyword.merge([options: %{responder: responder(self())}], opts[:model] || [])
        )

      {:ok, id} = Pie.start_agent([model: model] ++ Keyword.delete(opts, :model))
      on_exit(fn -> Pie.stop_agent(id) end)
      Pie.subscribe(id)
      id
    end

    defp talk(id, text) do
      :ok = Pie.prompt(id, text)
      Pie.await(id)
    end

    test "manual compaction appends an entry and changes the projection, not the log" do
      # Replies are ~125 estimated tokens and "three" ~1, so 126 cuts at "three".
      id = start(compaction: [keep_recent_tokens: 126])
      for text <- ["one", "two", "three"], do: talk(id, text)
      assert :ok = Pie.compact(id, "the numbers")
      Pie.await(id)

      assert_receive {:pie_event, ^id, {:compaction_start, :manual}}
      assert_receive {:pie_event, ^id, {:compaction_end, {:ok, %{summary: "SUMMARY 4"}}}}
      assert_receive {:summarizer_saw, prompt}
      assert prompt =~ "[User]: one" and prompt =~ "Focus especially on: the numbers"

      [summary | kept] = Pie.snapshot(id).messages
      assert Message.text(summary) =~ "SUMMARY 4"
      assert Enum.map(kept, &Message.text/1) == ["three", String.duplicate("word ", 100)]

      entries = Pie.Session.entries(Pie.session(id))
      assert Enum.count(entries, &(&1["type"] == "message")) == 6
      assert Enum.count(entries, &(&1["type"] == "compaction")) == 1

      talk(id, "four")
      assert_receive {:model_saw, [first, "three", _, "four"]}
      assert first =~ "SUMMARY 4"
    end

    test "compaction starts on its own when the context nears the window" do
      id =
        start(
          model: [context_window: 300],
          compaction: [reserve_tokens: 100, keep_recent_tokens: 10]
        )

      talk(id, "one")
      talk(id, "two")

      assert_receive {:pie_event, ^id, {:compaction_start, :threshold}}
      assert_receive {:pie_event, ^id, {:compaction_end, {:ok, _}}}
      assert [summary | _] = Pie.snapshot(id).messages
      assert Message.text(summary) =~ "<summary>"
    end

    test "a second compaction folds in the previous summary" do
      id = start(compaction: [keep_recent_tokens: 50])
      talk(id, "one")
      talk(id, "two")
      :ok = Pie.compact(id)
      Pie.await(id)
      talk(id, "three")
      :ok = Pie.compact(id)
      Pie.await(id)

      assert_receive {:summarizer_saw, _first}
      assert_receive {:summarizer_saw, second}
      assert second =~ "<previous-summary>\nSUMMARY"
    end

    test "prompts are refused while compacting and queued messages wait" do
      slow = fn context ->
        if context.system_prompt =~ "summarize",
          do: Process.sleep(200) && "S",
          else: String.duplicate("w ", 100)
      end

      id = start(model: [options: %{responder: slow}], compaction: [keep_recent_tokens: 10])
      talk(id, "one")
      talk(id, "two")
      :ok = Pie.compact(id)
      assert {:error, :compacting} = Pie.prompt(id, "now?")
      assert {:ok, :queued} = Pie.follow_up(id, "after compaction")
      Pie.await(id)

      assert Message.text(List.last(Pie.snapshot(id).messages)) =~ "w w"
      assert Enum.any?(Pie.snapshot(id).messages, &(Message.text(&1) == "after compaction"))
    end
  end
end
