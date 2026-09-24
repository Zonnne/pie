defmodule Pie.AI.Codec do
  @moduledoc """
  JSON mapping for messages, used by session files and the JSON event mode.
  Field names follow Pi's camelCase session format.
  """
  alias Pie.AI.{AssistantMessage, Text, Thinking, ToolCall, ToolResultMessage, Usage, UserMessage}

  @stop_reasons %{
    stop: "stop",
    length: "length",
    tool_use: "toolUse",
    error: "error",
    aborted: "aborted"
  }
  @stop_atoms Map.new(@stop_reasons, fn {k, v} -> {v, k} end)

  @spec encode(Pie.AI.Message.t()) :: map()
  def encode(%UserMessage{} = m) do
    %{
      "role" => "user",
      "content" => Enum.map(m.content, &encode_block/1),
      "timestamp" => m.timestamp
    }
  end

  def encode(%AssistantMessage{} = m) do
    %{
      "role" => "assistant",
      "content" => Enum.map(m.content, &encode_block/1),
      "provider" => m.provider,
      "model" => m.model,
      "usage" => %{
        "input" => m.usage.input,
        "output" => m.usage.output,
        "cacheRead" => m.usage.cache_read,
        "cacheWrite" => m.usage.cache_write
      },
      "stopReason" => Map.get(@stop_reasons, m.stop_reason),
      "errorMessage" => m.error_message,
      "timestamp" => m.timestamp
    }
  end

  def encode(%ToolResultMessage{} = m) do
    %{
      "role" => "toolResult",
      "toolCallId" => m.tool_call_id,
      "toolName" => m.tool_name,
      "content" => Enum.map(m.content, &encode_block/1),
      "details" => m.details,
      "isError" => m.is_error,
      "timestamp" => m.timestamp
    }
  end

  @spec decode(map()) :: Pie.AI.Message.t()
  def decode(%{"role" => "user"} = m) do
    %UserMessage{content: decode_blocks(m["content"]), timestamp: m["timestamp"]}
  end

  def decode(%{"role" => "assistant"} = m) do
    usage = m["usage"] || %{}

    %AssistantMessage{
      content: decode_blocks(m["content"]),
      provider: m["provider"],
      model: m["model"],
      usage: %Usage{
        input: usage["input"] || 0,
        output: usage["output"] || 0,
        cache_read: usage["cacheRead"] || 0,
        cache_write: usage["cacheWrite"] || 0
      },
      stop_reason: Map.get(@stop_atoms, m["stopReason"]),
      error_message: m["errorMessage"],
      timestamp: m["timestamp"]
    }
  end

  def decode(%{"role" => "toolResult"} = m) do
    %ToolResultMessage{
      tool_call_id: m["toolCallId"],
      tool_name: m["toolName"],
      content: decode_blocks(m["content"]),
      details: m["details"],
      is_error: m["isError"] == true,
      timestamp: m["timestamp"]
    }
  end

  @spec encode_block(struct()) :: map()
  def encode_block(%Text{text: t}), do: %{"type" => "text", "text" => t}

  def encode_block(%Thinking{} = b),
    do: %{"type" => "thinking", "thinking" => b.thinking, "thinkingSignature" => b.signature}

  def encode_block(%ToolCall{} = c),
    do: %{"type" => "toolCall", "id" => c.id, "name" => c.name, "arguments" => c.arguments}

  defp decode_blocks(text) when is_binary(text), do: [%Text{text: text}]
  defp decode_blocks(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &decode_block/1)
  defp decode_blocks(_), do: []

  defp decode_block(%{"type" => "text", "text" => t}), do: [%Text{text: t}]

  defp decode_block(%{"type" => "thinking"} = b),
    do: [%Thinking{thinking: b["thinking"] || "", signature: b["thinkingSignature"]}]

  defp decode_block(%{"type" => "toolCall"} = c),
    do: [%ToolCall{id: c["id"], name: c["name"], arguments: c["arguments"] || %{}}]

  defp decode_block(_unknown), do: []
end
