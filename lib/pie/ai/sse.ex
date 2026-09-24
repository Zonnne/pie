defmodule Pie.AI.SSE do
  @moduledoc """
  A server-sent-events parser. Pure: feed it the buffered bytes, get back
  complete events and the unconsumed remainder to prepend to the next chunk.
  """

  @type event :: %{event: String.t() | nil, data: String.t()}

  @spec parse(binary()) :: {[event()], binary()}
  def parse(buffer) do
    parts = buffer |> String.replace("\r\n", "\n") |> String.split("\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &parse_event/1), rest}
  end

  defp parse_event(block) do
    {name, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn
        "event:" <> value, {_, data} -> {String.trim(value), data}
        "data: " <> value, {name, data} -> {name, [value | data]}
        "data:" <> value, {name, data} -> {name, [value | data]}
        _comment_or_other, acc -> acc
      end)

    case {name, data} do
      {nil, []} -> []
      _ -> [%{event: name, data: data |> Enum.reverse() |> Enum.join("\n")}]
    end
  end
end
