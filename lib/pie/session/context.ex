defmodule Pie.Session.Context do
  @moduledoc """
  The context projection: turns the entries on a branch into the messages an
  agent works with. Entry types it does not understand are ignored, so newer
  logs stay readable by older code.
  """
  alias Pie.AI.Codec

  @spec messages([Pie.Session.entry()]) :: [Pie.AI.Message.t()]
  def messages(path) do
    for %{"type" => "message", "message" => message} <- path, do: Codec.decode(message)
  end
end
