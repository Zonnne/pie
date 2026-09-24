defmodule Pie.AI.Context do
  @moduledoc """
  Everything a model sees for one request.

  `tools` are any maps or structs with `:name`, `:description` and
  `:parameters` (a JSON Schema); `Pie.Tool` structs qualify, so the agent
  passes its tools straight through.
  """
  alias Pie.AI.Message

  defstruct system_prompt: nil, messages: [], tools: []

  @type tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map(),
          optional(atom()) => term()
        }
  @type t :: %__MODULE__{
          system_prompt: String.t() | nil,
          messages: [Message.t()],
          tools: [tool()]
        }
end
