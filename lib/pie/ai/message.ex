defmodule Pie.AI.Text do
  @moduledoc "A text content block."
  defstruct text: ""
  @type t :: %__MODULE__{text: String.t()}
end

defmodule Pie.AI.Thinking do
  @moduledoc "A reasoning block. The signature must be replayed verbatim to the provider."
  defstruct thinking: "", signature: nil
  @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
end

defmodule Pie.AI.ToolCall do
  @moduledoc "A request from the model to run a tool. `arguments` is decoded JSON."
  defstruct [:id, :name, arguments: %{}]
  @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}
end

defmodule Pie.AI.Usage do
  @moduledoc "Token accounting for one assistant message."
  defstruct input: 0, output: 0, cache_read: 0, cache_write: 0

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @doc "Tokens the request occupied in the context window, including the reply."
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = u), do: u.input + u.output + u.cache_read + u.cache_write
end

defmodule Pie.AI.UserMessage do
  @moduledoc "A message from the user. Content is always a list of blocks."
  alias Pie.AI.Text

  defstruct content: [], timestamp: nil
  @type t :: %__MODULE__{content: [Text.t()], timestamp: integer() | nil}

  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    %__MODULE__{content: [%Text{text: text}], timestamp: Pie.AI.Message.now()}
  end
end

defmodule Pie.AI.AssistantMessage do
  @moduledoc """
  A reply from the model. `stop_reason` says how the reply ended:
  `:stop`, `:length` and `:tool_use` are successes, `:error` and `:aborted`
  are failures (with `error_message` set). Failures are values, not raises.
  """
  alias Pie.AI.{Text, Thinking, ToolCall, Usage}

  defstruct content: [],
            provider: nil,
            model: nil,
            usage: %Usage{},
            stop_reason: nil,
            error_message: nil,
            timestamp: nil

  @type stop_reason :: :stop | :length | :tool_use | :error | :aborted
  @type t :: %__MODULE__{
          content: [Text.t() | Thinking.t() | ToolCall.t()],
          provider: String.t() | nil,
          model: String.t() | nil,
          usage: Usage.t(),
          stop_reason: stop_reason() | nil,
          error_message: String.t() | nil,
          timestamp: integer() | nil
        }
end

defmodule Pie.AI.ToolResultMessage do
  @moduledoc "The outcome of one tool call, sent back to the model."
  alias Pie.AI.Text

  defstruct [
    :tool_call_id,
    :tool_name,
    content: [],
    details: nil,
    is_error: false,
    timestamp: nil
  ]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          tool_name: String.t(),
          content: [Text.t()],
          details: term(),
          is_error: boolean(),
          timestamp: integer() | nil
        }
end

defmodule Pie.AI.Message do
  @moduledoc "Helpers over the three message types."
  alias Pie.AI.{AssistantMessage, Text, ToolCall, ToolResultMessage, UserMessage}

  @type t :: UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t()

  @doc "Milliseconds since the epoch, the timestamp unit used everywhere."
  def now, do: System.system_time(:millisecond)

  @doc "The concatenated text blocks of a message."
  @spec text(t()) :: String.t()
  def text(%{content: content}), do: Enum.join(for(%Text{text: t} <- content, do: t))

  @spec tool_calls(t()) :: [ToolCall.t()]
  def tool_calls(%AssistantMessage{content: content}), do: for(%ToolCall{} = c <- content, do: c)
  def tool_calls(_), do: []

  @doc "True for the three message structs the model understands."
  def llm?(%struct{}) when struct in [UserMessage, AssistantMessage, ToolResultMessage], do: true
  def llm?(_), do: false
end
