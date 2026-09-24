defmodule Pie.Session.Context do
  @moduledoc """
  The context projection: turns the entries on a branch into the messages an
  agent works with.

  The latest compaction entry on the branch replaces everything before its
  `firstKeptEntryId` with one summary message; messages from that entry on
  (and everything after the compaction) are kept verbatim. Entry types the
  projection does not understand are ignored, so newer logs stay readable.
  """
  alias Pie.AI.{Codec, Text, UserMessage}

  @summary_prefix "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"

  @spec messages([Pie.Session.entry()]) :: [Pie.AI.Message.t()]
  def messages(path) do
    {compaction, kept} = project(path)
    summary(compaction) ++ Enum.map(kept, &Codec.decode(&1["message"]))
  end

  @doc "The latest compaction on the branch (or nil) and the message entries still in context."
  @spec project([Pie.Session.entry()]) :: {Pie.Session.entry() | nil, [Pie.Session.entry()]}
  def project(path) do
    last =
      path
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _} -> entry["type"] == "compaction" end)
      |> List.last()

    case last do
      nil ->
        {nil, message_entries(path)}

      {compaction, index} ->
        {before, [_compaction | rest]} = Enum.split(path, index)
        kept = Enum.drop_while(before, &(&1["id"] != compaction["firstKeptEntryId"]))
        {compaction, message_entries(kept ++ rest)}
    end
  end

  defp message_entries(entries), do: Enum.filter(entries, &(&1["type"] == "message"))

  defp summary(nil), do: []

  defp summary(compaction) do
    [
      %UserMessage{
        content: [%Text{text: @summary_prefix <> compaction["summary"] <> "\n</summary>"}],
        timestamp: timestamp(compaction["timestamp"])
      }
    ]
  end

  defp timestamp(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end
end
