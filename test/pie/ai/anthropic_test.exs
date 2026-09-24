defmodule Pie.AI.AnthropicTest do
  use ExUnit.Case, async: true

  alias Pie.AI

  alias Pie.AI.{
    AssistantMessage,
    Context,
    Model,
    Text,
    Thinking,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  alias Pie.AI.Providers.Anthropic
  alias Pie.Test.SSEServer

  @tool %{name: "read", description: "Read a file", parameters: %{type: "object"}}

  defp events(extra_blocks \\ []) do
    SSEServer.sse(
      [
        %{
          "type" => "message_start",
          "message" => %{"usage" => %{"input_tokens" => 12, "output_tokens" => 1}}
        },
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        %{"type" => "ping"},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Let me "}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "look."}
        },
        %{"type" => "content_block_stop", "index" => 0}
      ] ++
        extra_blocks ++
        [
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 30}
          },
          %{"type" => "message_stop"}
        ]
    )
  end

  defp tool_block do
    [
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "read",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":)}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("mix.exs"})}
      },
      %{"type" => "content_block_stop", "index" => 1}
    ]
  end

  test "streams a real HTTP response into typed events" do
    test = self()

    url =
      SSEServer.start(fn body ->
        send(test, {:request, JSON.decode!(body)})
        {200, events(tool_block())}
      end)

    model = Model.new(:anthropic, "test-model", base_url: url, max_tokens: 1000)

    context = %Context{
      system_prompt: "Be brief.",
      messages: [UserMessage.new("hi")],
      tools: [@tool]
    }

    events = model |> AI.stream(context, api_key: "k") |> Enum.to_list()
    assert_receive {:request, request}

    assert request["model"] == "test-model"
    assert request["stream"] == true
    assert [%{"text" => "Be brief.", "cache_control" => _}] = request["system"]
    assert [%{"name" => "read", "input_schema" => %{"type" => "object"}}] = request["tools"]

    assert Enum.map(events, &elem(&1, 0)) ==
             [:start, :text_start, :text_delta, :text_delta, :text_end] ++
               [:toolcall_start, :toolcall_delta, :toolcall_delta, :toolcall_end, :done]

    assert {:done, :tool_use, %AssistantMessage{} = message} = List.last(events)

    assert message.content == [
             %Text{text: "Let me look."},
             %ToolCall{id: "toolu_1", name: "read", arguments: %{"path" => "mix.exs"}}
           ]

    assert message.usage.input == 12 and message.usage.output == 30
    refute_receive {:http, _}, 50
  end

  test "HTTP errors become an error event, not an exception" do
    url =
      SSEServer.start(fn _ ->
        {401, [~s({"error":{"type":"auth","message":"invalid x-api-key"}})]}
      end)

    model = Model.new(:anthropic, "m", base_url: url)

    assert %AssistantMessage{stop_reason: :error, error_message: "HTTP 401: invalid x-api-key"} =
             AI.complete(model, %Context{messages: [UserMessage.new("hi")]}, api_key: "bad")
  end

  test "overloaded responses are retried before streaming starts" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    url =
      SSEServer.start(fn _ ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> {529, [~s({"error":{"type":"overloaded_error","message":"Overloaded"}})]}
          _ -> {200, events(tool_block())}
        end
      end)

    model = Model.new(:anthropic, "m", base_url: url)
    opts = [api_key: "k", req_options: [retry_delay: fn _ -> 10 end]]

    assert %AssistantMessage{stop_reason: :tool_use} =
             AI.complete(model, %Context{messages: [UserMessage.new("hi")]}, opts)

    assert Agent.get(attempts, & &1) == 2
  end

  test "a missing API key is an error event" do
    model = Model.new(:anthropic, "m", base_url: "http://127.0.0.1:1")

    assert %AssistantMessage{stop_reason: :error, error_message: "ANTHROPIC_API_KEY is not set"} =
             AI.complete(model, %Context{messages: []}, api_key: "")
  end

  test "abort mid-stream keeps the partial reply and cancels the request" do
    [first | rest] = events()

    url =
      SSEServer.start(fn _ ->
        {200, [first, Enum.at(rest, 0), Enum.at(rest, 2), {:sleep, 2_000}] ++ rest}
      end)

    model = Model.new(:anthropic, "m", base_url: url)
    signal = make_ref()

    message =
      model
      |> AI.stream(%Context{messages: [UserMessage.new("hi")]}, api_key: "k", signal: signal)
      |> Enum.reduce(nil, fn
        {:text_delta, _, _, _}, acc ->
          send(self(), {:abort, signal})
          acc

        {type, _, message}, _ when type in [:done, :error] ->
          message

        _, acc ->
          acc
      end)

    assert %AssistantMessage{stop_reason: :aborted, content: [%Text{text: "Let me "}]} = message
  end

  describe "request body" do
    test "normalizes history, merges user turns and marks the cache breakpoint" do
      call = %ToolCall{id: "t1", name: "read", arguments: %{}}

      context = %Context{
        messages: [
          UserMessage.new("hi"),
          %AssistantMessage{
            content: [
              %Thinking{thinking: "no sig"},
              %Thinking{thinking: "t", signature: "s"},
              %Text{text: " "},
              call
            ],
            stop_reason: :tool_use
          },
          %ToolResultMessage{
            tool_call_id: "t1",
            tool_name: "read",
            content: [%Text{text: "data"}]
          },
          UserMessage.new("steer")
        ]
      }

      body = Anthropic.body(Model.new(:anthropic, "m"), context, [])

      assert [
               %{"role" => "user", "content" => [%{"text" => "hi"}]},
               %{
                 "role" => "assistant",
                 "content" => [%{"type" => "thinking"}, %{"type" => "tool_use", "input" => %{}}]
               },
               %{
                 "role" => "user",
                 "content" => [%{"type" => "tool_result", "tool_use_id" => "t1"}, last]
               }
             ] = body["messages"]

      assert last == %{
               "type" => "text",
               "text" => "steer",
               "cache_control" => %{"type" => "ephemeral"}
             }

      refute Map.has_key?(body, "system")
      assert JSON.encode!(body) =~ ~s("input":{})
    end
  end
end
