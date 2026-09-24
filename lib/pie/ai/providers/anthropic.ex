defmodule Pie.AI.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API over server-sent events.

  Uses only OTP: `:httpc` for HTTP (in async streaming mode, so body chunks
  arrive as messages in the consuming process), `:ssl` and
  `:public_key.cacerts_get/0` for verified TLS. The stream is an Elixir
  `Stream.resource/3`, so the HTTP request lives exactly as long as someone
  is consuming it: halting the stream early cancels the request.

  Options: `:api_key` (default `ANTHROPIC_API_KEY`), `:max_tokens`,
  `:thinking_budget`, `:signal`. The base URL comes from the model, then
  `ANTHROPIC_BASE_URL`, then the public endpoint.
  """
  @behaviour Pie.AI.Provider

  alias Pie.AI.{Accumulator, AssistantMessage, SSE, Transform}
  alias Pie.AI.{Text, Thinking, ToolCall, ToolResultMessage, UserMessage}

  @default_base_url "https://api.anthropic.com"
  @idle_timeout :timer.minutes(5)
  @ephemeral %{"type" => "ephemeral"}

  @impl true
  def stream(model, context, opts) do
    Stream.resource(fn -> open(model, context, opts) end, &next/1, &close/1)
  end

  ## Stream lifecycle

  defp open(model, context, opts) do
    state = %{
      acc: Accumulator.new(model),
      request: nil,
      buffer: "",
      signal: opts[:signal] || make_ref(),
      phase: :start,
      error: nil
    }

    case Keyword.get_lazy(opts, :api_key, fn -> System.get_env("ANTHROPIC_API_KEY") end) do
      key when key in [nil, ""] ->
        %{state | error: "ANTHROPIC_API_KEY is not set"}

      key ->
        case request(model, context, key, opts) do
          {:ok, id} -> %{state | request: id}
          {:error, reason} -> %{state | error: "Request failed: #{inspect(reason)}"}
        end
    end
  end

  defp next(%{phase: :start, error: nil} = s),
    do: {[Accumulator.start(s.acc)], %{s | phase: :streaming}}

  defp next(%{phase: :start} = s) do
    {[Accumulator.start(s.acc), Accumulator.fail(s.acc, :error, s.error)], %{s | phase: :halted}}
  end

  defp next(%{phase: :halted} = s), do: {:halt, s}

  # After message_stop the server closes the stream; wait briefly for that so
  # no stray :httpc messages are left in the consumer's mailbox.
  defp next(%{phase: :draining, request: id} = s) do
    receive do
      {:http, {^id, :stream_end, _}} -> {:halt, %{s | request: nil}}
      {:http, {^id, {:error, _}}} -> {:halt, %{s | request: nil}}
    after
      5_000 -> {:halt, s}
    end
  end

  defp next(%{phase: :streaming, request: id, signal: signal} = s) do
    receive do
      {:http, {^id, :stream_start, _headers}} ->
        {[], s}

      {:http, {^id, :stream, chunk}} ->
        consume(s, chunk)

      {:http, {^id, :stream_end, _headers}} ->
        fail(%{s | request: nil}, :error, "Stream ended before message_stop")

      {:http, {^id, {{_, status, _}, _headers, body}}} ->
        fail(%{s | request: nil}, :error, "HTTP #{status}: #{error_message(body)}")

      {:http, {^id, {:error, reason}}} ->
        fail(%{s | request: nil}, :error, "HTTP error: #{inspect(reason)}")

      {:abort, ^signal} ->
        fail(s, :aborted, "Request aborted")
    after
      @idle_timeout -> fail(s, :error, "No data from provider for #{div(@idle_timeout, 1000)}s")
    end
  end

  defp close(%{request: nil}), do: :ok
  defp close(%{request: id}), do: cancel(id)

  defp cancel(nil), do: :ok

  defp cancel(id) do
    :httpc.cancel_request(id)
    flush(id)
  end

  defp flush(id) do
    receive do
      {:http, {^id, _}} -> flush(id)
    after
      0 -> :ok
    end
  end

  defp fail(s, reason, message) do
    cancel(s.request)
    {[Accumulator.fail(s.acc, reason, message)], %{s | request: nil, phase: :halted}}
  end

  defp consume(s, chunk) do
    {events, buffer} = SSE.parse(s.buffer <> chunk)
    fold(Enum.flat_map(events, &to_deltas/1), %{s | buffer: buffer}, [])
  end

  defp fold([], s, out), do: {Enum.reverse(out), s}

  defp fold([:finish | _], s, out) do
    {Enum.reverse([Accumulator.finish(s.acc) | out]), %{s | phase: :draining}}
  end

  defp fold([{:fail, message} | _], s, out) do
    {events, s} = fail(s, :error, message)
    {Enum.reverse(out) ++ events, s}
  end

  defp fold([delta | rest], s, out) do
    {events, acc} = Accumulator.apply(s.acc, delta)
    fold(rest, %{s | acc: acc}, Enum.reverse(events) ++ out)
  end

  ## Wire format -> neutral deltas

  defp to_deltas(%{data: data}) do
    case JSON.decode(data) do
      {:ok, %{} = event} -> deltas(event)
      _ -> []
    end
  end

  defp deltas(%{"type" => "message_start", "message" => message}),
    do: [{:usage, usage(message["usage"])}]

  defp deltas(%{"type" => "content_block_start", "index" => i, "content_block" => block}) do
    case block do
      %{"type" => "text"} ->
        [{:block_start, i, :text}]

      %{"type" => "thinking"} ->
        [{:block_start, i, :thinking}]

      %{"type" => "tool_use", "id" => id, "name" => name} ->
        [{:block_start, i, {:tool_call, id, name}}]

      _ ->
        []
    end
  end

  defp deltas(%{"type" => "content_block_delta", "index" => i, "delta" => delta}) do
    case delta do
      %{"type" => "text_delta", "text" => text} -> [{:block_delta, i, text}]
      %{"type" => "thinking_delta", "thinking" => text} -> [{:block_delta, i, text}]
      %{"type" => "input_json_delta", "partial_json" => json} -> [{:block_delta, i, json}]
      %{"type" => "signature_delta", "signature" => sig} -> [{:block_signature, i, sig}]
      _ -> []
    end
  end

  defp deltas(%{"type" => "content_block_stop", "index" => i}), do: [{:block_stop, i}]

  defp deltas(%{"type" => "message_delta"} = event) do
    [{:usage, usage(event["usage"])} | stop_reason(get_in(event, ["delta", "stop_reason"]))]
  end

  defp deltas(%{"type" => "message_stop"}), do: [:finish]

  defp deltas(%{"type" => "error", "error" => error}),
    do: [{:fail, error["message"] || inspect(error)}]

  defp deltas(_ping_or_unknown), do: []

  defp stop_reason(nil), do: []
  defp stop_reason("tool_use"), do: [{:stop_reason, :tool_use}]
  defp stop_reason("max_tokens"), do: [{:stop_reason, :length}]
  defp stop_reason("refusal"), do: [{:fail, "The model declined to respond"}]
  defp stop_reason(_end_turn_or_stop_sequence), do: [{:stop_reason, :stop}]

  defp usage(nil), do: %{}

  defp usage(u) do
    %{
      input: u["input_tokens"],
      output: u["output_tokens"],
      cache_read: u["cache_read_input_tokens"],
      cache_write: u["cache_creation_input_tokens"]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp error_message(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> String.slice(body, 0, 500)
    end
  end

  ## Request

  defp request(model, context, key, opts) do
    base = model.base_url || System.get_env("ANTHROPIC_BASE_URL") || @default_base_url
    url = String.to_charlist(String.trim_trailing(base, "/") <> "/v1/messages")

    headers = [
      {~c"x-api-key", String.to_charlist(key)},
      {~c"anthropic-version", ~c"2023-06-01"},
      {~c"accept", ~c"text/event-stream"}
    ]

    body = JSON.encode!(body(model, context, opts))
    http_opts = [connect_timeout: 30_000, ssl: ssl_opts()]

    :httpc.request(:post, {url, headers, ~c"application/json", body}, http_opts,
      sync: false,
      stream: :self,
      body_format: :binary
    )
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @doc false
  # Public for tests: the exact JSON body sent for a context.
  def body(model, context, opts) do
    messages =
      context.messages
      |> Transform.normalize()
      |> Enum.flat_map(&message/1)
      |> merge_roles()
      |> cache_last()

    %{
      "model" => model.id,
      "max_tokens" => Keyword.get(opts, :max_tokens, model.max_tokens),
      "stream" => true,
      "messages" => messages
    }
    |> put_present("system", system(context.system_prompt))
    |> put_present("tools", Enum.map(context.tools, &tool/1))
    |> put_present("thinking", thinking(opts[:thinking_budget]))
  end

  defp system(prompt) when prompt in [nil, ""], do: nil
  defp system(prompt), do: [%{"type" => "text", "text" => prompt, "cache_control" => @ephemeral}]

  defp thinking(nil), do: nil
  defp thinking(budget), do: %{"type" => "enabled", "budget_tokens" => budget}

  defp tool(t),
    do: %{"name" => t.name, "description" => t.description, "input_schema" => t.parameters}

  defp put_present(map, _key, value) when value in [nil, []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp message(%UserMessage{content: content}) do
    case text_blocks(content) do
      [] -> []
      blocks -> [%{"role" => "user", "content" => blocks}]
    end
  end

  defp message(%AssistantMessage{content: content}) do
    case Enum.flat_map(content, &assistant_block/1) do
      [] -> []
      blocks -> [%{"role" => "assistant", "content" => blocks}]
    end
  end

  defp message(%ToolResultMessage{} = m) do
    result = %{"type" => "tool_result", "tool_use_id" => m.tool_call_id, "is_error" => m.is_error}
    result = put_present(result, "content", text_blocks(m.content))
    [%{"role" => "user", "content" => [result]}]
  end

  defp text_blocks(content) do
    for %Text{text: t} <- content, String.trim(t) != "", do: %{"type" => "text", "text" => t}
  end

  defp assistant_block(%Text{} = b), do: text_blocks([b])

  defp assistant_block(%Thinking{signature: sig} = b) when is_binary(sig) and sig != "",
    do: [%{"type" => "thinking", "thinking" => b.thinking, "signature" => sig}]

  defp assistant_block(%Thinking{}), do: []

  defp assistant_block(%ToolCall{} = c),
    do: [%{"type" => "tool_use", "id" => c.id, "name" => c.name, "input" => c.arguments}]

  # Tool results and follow-up text become consecutive user turns; the API
  # wants them as one turn.
  defp merge_roles(messages) do
    messages
    |> Enum.chunk_by(& &1["role"])
    |> Enum.map(fn [first | _] = group ->
      %{first | "content" => Enum.flat_map(group, & &1["content"])}
    end)
  end

  # Cache the whole prefix up to the newest message (the system prompt and
  # tools are cached by the system block's breakpoint).
  defp cache_last([]), do: []

  defp cache_last(messages) do
    List.update_at(messages, -1, fn m ->
      %{
        m
        | "content" => List.update_at(m["content"], -1, &Map.put(&1, "cache_control", @ephemeral))
      }
    end)
  end
end
