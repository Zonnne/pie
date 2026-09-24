defmodule Pie.AI.StreamTest do
  use ExUnit.Case, async: true

  alias Pie.AI

  alias Pie.AI.{
    Accumulator,
    AssistantMessage,
    Context,
    Model,
    SSE,
    Text,
    Thinking,
    ToolCall,
    Transform
  }

  alias Pie.AI.{ToolResultMessage, UserMessage}
  alias Pie.AI.Providers.Faux

  describe "SSE" do
    test "parses events split across arbitrary chunk boundaries" do
      wire =
        "event: a\ndata: {\"x\":1}\n\n: comment\n\nevent: b\r\ndata: line1\r\ndata: line2\r\n\r\n"

      events =
        wire
        |> String.graphemes()
        |> Enum.reduce({[], ""}, fn char, {events, buffer} ->
          {new, rest} = SSE.parse(buffer <> char)
          {events ++ new, rest}
        end)
        |> elem(0)

      assert events == [%{event: "a", data: ~s({"x":1})}, %{event: "b", data: "line1\nline2"}]
    end
  end

  describe "Accumulator" do
    test "folds deltas into typed events that carry the partial message" do
      acc = Accumulator.new(Model.new(:test, "m"))

      {events, acc} =
        [
          {:usage, %{input: 10}},
          {:block_start, 0, :thinking},
          {:block_delta, 0, "hmm"},
          {:block_signature, 0, "sig"},
          {:block_stop, 0},
          {:block_start, 1, :text},
          {:block_delta, 1, "Hel"},
          {:block_delta, 1, "lo"},
          {:block_stop, 1},
          {:block_start, 2, {:tool_call, "t1", "read"}},
          {:block_delta, 2, ~s({"pa)},
          {:block_delta, 2, ~s(th":"a.txt"})},
          {:block_stop, 2},
          {:block_delta, 9, "ignored: unknown index"},
          {:usage, %{output: 5}},
          {:stop_reason, :tool_use}
        ]
        |> Enum.reduce({[], acc}, fn delta, {events, acc} ->
          {new, acc} = Accumulator.apply(acc, delta)
          {events ++ new, acc}
        end)

      assert Enum.map(events, &elem(&1, 0)) == [
               :thinking_start,
               :thinking_delta,
               :thinking_end,
               :text_start,
               :text_delta,
               :text_delta,
               :text_end,
               :toolcall_start,
               :toolcall_delta,
               :toolcall_delta,
               :toolcall_end
             ]

      assert {:text_delta, 1, "lo", %AssistantMessage{content: [_, %Text{text: "Hello"}]}} =
               Enum.at(events, 5)

      assert {:done, :tool_use, message} = Accumulator.finish(acc)

      assert message.content == [
               %Thinking{thinking: "hmm", signature: "sig"},
               %Text{text: "Hello"},
               %ToolCall{id: "t1", name: "read", arguments: %{"path" => "a.txt"}}
             ]

      assert message.usage.input == 10 and message.usage.output == 5
    end

    test "failure keeps partial content" do
      acc = Accumulator.new(Model.new(:test, "m"))
      {_, acc} = Accumulator.apply(acc, {:block_start, 0, :text})
      {_, acc} = Accumulator.apply(acc, {:block_delta, 0, "partial"})

      assert {:error, :aborted,
              %AssistantMessage{stop_reason: :aborted, content: [%Text{text: "partial"}]}} =
               Accumulator.fail(acc, :aborted, "Request aborted")
    end
  end

  describe "Transform.normalize/1" do
    test "drops failed turns and pairs every tool call with exactly one result" do
      call = %ToolCall{id: "c1", name: "bash", arguments: %{}}

      history = [
        UserMessage.new("hi"),
        %AssistantMessage{content: [%Text{text: "half"}], stop_reason: :aborted},
        %AssistantMessage{content: [call], stop_reason: :tool_use},
        %ToolResultMessage{tool_call_id: "gone", tool_name: "x"},
        UserMessage.new("next")
      ]

      assert [
               %UserMessage{},
               %AssistantMessage{stop_reason: :tool_use},
               %ToolResultMessage{tool_call_id: "c1", is_error: true},
               %UserMessage{}
             ] = Transform.normalize(history)
    end
  end

  describe "Faux provider" do
    test "streams scripted replies through the same typed events" do
      model =
        Model.new(:faux, "faux",
          options: %{responder: Faux.sequence(["one two", {:error, "boom"}])}
        )

      events = model |> AI.stream(%Context{messages: [UserMessage.new("x")]}) |> Enum.to_list()
      assert {:start, _} = hd(events)
      assert {:done, :stop, %AssistantMessage{} = message} = List.last(events)
      assert Pie.AI.Message.text(message) == "one two"

      assert %AssistantMessage{stop_reason: :error, error_message: "boom"} =
               AI.complete(model, %Context{messages: []})
    end

    test "aborts on {:abort, signal} and returns the partial message" do
      model =
        Model.new(:faux, "faux", options: %{responder: fn _ -> "a b c d e f" end, delay: 20})

      signal = make_ref()
      send(self(), {:abort, signal})

      assert %AssistantMessage{stop_reason: :aborted} =
               AI.complete(model, %Context{messages: []}, signal: signal)
    end
  end
end
