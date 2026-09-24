defmodule Pie.Agent.Event do
  @moduledoc """
  The lifecycle vocabulary. Every transition of an agent is one of these
  events, delivered in order to subscribers as `{:pie_event, agent_id, event}`.

  From the loop (one run):

      :agent_start
      :turn_start
      {:message_start, message}          # user, assistant (partial) or tool result
      {:message_update, Pie.AI.event()}  # streaming deltas of the assistant reply
      {:message_end, message}            # final message; persisted before delivery
      {:tool_execution_start, tool_call}
      {:tool_execution_update, tool_call, partial_output}
      {:tool_execution_end, tool_call, tool_result_message}
      {:turn_end, assistant_message, [tool_result_message]}
      {:agent_end, [new_message]}

  From the runtime itself:

      {:compaction_start, :manual | :threshold}
      {:compaction_end, {:ok, compaction} | :noop | {:error, reason}}
      {:run_crashed, reason}

  `to_json/1` renders any event as a JSON-ready map, the basis of the CLI's
  `--mode json`.
  """
  alias Pie.AI.Codec

  @type t :: atom() | tuple()

  @spec to_json(t()) :: map()
  def to_json(event) when is_atom(event), do: %{"type" => Atom.to_string(event)}

  def to_json({type, message}) when type in [:message_start, :message_end],
    do: %{"type" => Atom.to_string(type), "message" => Codec.encode(message)}

  def to_json({:message_update, event}),
    do: %{"type" => "message_update", "event" => stream_event(event)}

  def to_json({:tool_execution_start, call}), do: tool("tool_execution_start", call, %{})

  def to_json({:tool_execution_update, call, partial}),
    do: tool("tool_execution_update", call, %{"partialResult" => partial})

  def to_json({:tool_execution_end, call, result}),
    do:
      tool("tool_execution_end", call, %{
        "result" => Codec.encode(result),
        "isError" => result.is_error
      })

  def to_json({:turn_end, message, results}) do
    %{
      "type" => "turn_end",
      "message" => Codec.encode(message),
      "toolResults" => Enum.map(results, &Codec.encode/1)
    }
  end

  def to_json({:agent_end, messages}),
    do: %{"type" => "agent_end", "messages" => Enum.map(messages, &Codec.encode/1)}

  def to_json({:compaction_start, reason}),
    do: %{"type" => "compaction_start", "reason" => Atom.to_string(reason)}

  def to_json({:compaction_end, {:ok, compaction}}),
    do: %{
      "type" => "compaction_end",
      "summary" => compaction.summary,
      "tokensBefore" => compaction.tokens_before
    }

  def to_json({:compaction_end, other}),
    do: %{"type" => "compaction_end", "result" => inspect(other)}

  def to_json({:run_crashed, reason}), do: %{"type" => "run_crashed", "reason" => inspect(reason)}

  defp tool(type, call, extra) do
    Map.merge(
      %{
        "type" => type,
        "toolCallId" => call.id,
        "toolName" => call.name,
        "args" => call.arguments
      },
      extra
    )
  end

  defp stream_event({:start, _}), do: %{"type" => "start"}

  defp stream_event({type, index, _partial}),
    do: %{"type" => Atom.to_string(type), "contentIndex" => index}

  defp stream_event({type, index, delta, _})
       when type in [:text_delta, :thinking_delta, :toolcall_delta],
       do: %{"type" => Atom.to_string(type), "contentIndex" => index, "delta" => delta}

  defp stream_event({:toolcall_end, index, call, _}),
    do: %{
      "type" => "toolcall_end",
      "contentIndex" => index,
      "toolCall" => Codec.encode_block(call)
    }

  defp stream_event({type, index, content, _}),
    do: %{"type" => Atom.to_string(type), "contentIndex" => index, "content" => content}
end
