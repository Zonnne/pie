defmodule Pie.AI.Transform do
  @moduledoc """
  Makes any message history safe to send, whatever happened to produce it.

  Histories are append-only, so they contain the scars of real runs: replies
  that were aborted halfway through a tool call, turns that errored, a crash
  between a tool call and its result. Providers reject such histories, so
  before every request we:

    1. drop assistant messages that ended in `:error` or `:aborted` (they are
       incomplete turns; the model should continue from the last good state);
    2. give every tool call exactly one result, inserting a synthetic error
       result for calls that never got one and dropping results whose call is
       gone.

  The log keeps everything; only the projection sent to the model is cleaned.
  """
  alias Pie.AI.{AssistantMessage, Message, Text, ToolResultMessage}

  @spec normalize([Message.t()]) :: [Message.t()]
  def normalize(messages) do
    messages
    |> Enum.reject(&match?(%AssistantMessage{stop_reason: r} when r in [:error, :aborted], &1))
    |> pair_tool_results()
  end

  defp pair_tool_results(messages) do
    {out, pending} =
      Enum.reduce(messages, {[], []}, fn
        %ToolResultMessage{tool_call_id: id} = result, {out, pending} ->
          if Enum.any?(pending, &(&1.id == id)),
            do: {[result | out], Enum.reject(pending, &(&1.id == id))},
            else: {out, pending}

        %AssistantMessage{} = message, {out, pending} ->
          {[message | missing(pending) ++ out], Message.tool_calls(message)}

        message, {out, pending} ->
          {[message | missing(pending) ++ out], []}
      end)

    Enum.reverse(missing(pending) ++ out)
  end

  # Returned reversed, ready to prepend onto the reversed accumulator.
  defp missing(calls) do
    calls
    |> Enum.map(fn call ->
      %ToolResultMessage{
        tool_call_id: call.id,
        tool_name: call.name,
        content: [%Text{text: "No result provided (the tool run was interrupted)."}],
        is_error: true,
        timestamp: Message.now()
      }
    end)
    |> Enum.reverse()
  end
end
