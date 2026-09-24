defmodule Pie.AI.Accumulator do
  @moduledoc """
  Folds provider-neutral deltas into typed stream events.

  Providers only translate their wire format into these deltas:

      {:block_start, index, :text | :thinking | {:tool_call, id, name}}
      {:block_delta, index, binary}      # text, reasoning or raw JSON
      {:block_signature, index, binary}  # reasoning signature
      {:block_stop, index}
      {:usage, %{optional(:input | :output | :cache_read | :cache_write) => integer}}
      {:stop_reason, :stop | :length | :tool_use}

  `index` is the provider's block index; unknown indexes (blocks a provider
  chose not to open, e.g. redacted reasoning) are ignored. Keeping this logic
  in one pure module means every provider produces identical events, and the
  logic is tested once.
  """
  alias Pie.AI.{AssistantMessage, Message, Text, Thinking, ToolCall, Usage}

  defstruct [:message, positions: %{}, json: %{}]

  @type t :: %__MODULE__{
          message: AssistantMessage.t(),
          positions: %{term() => non_neg_integer()},
          json: %{non_neg_integer() => binary()}
        }

  @spec new(Pie.AI.Model.t()) :: t()
  def new(model) do
    %__MODULE__{
      message: %AssistantMessage{
        provider: to_string(model.provider),
        model: model.id,
        timestamp: Message.now()
      }
    }
  end

  @doc "The opening event of every stream."
  def start(%__MODULE__{message: message}), do: {:start, message}

  @doc "Applies one delta, returning the typed events it produced."
  @spec apply(t(), tuple()) :: {[Pie.AI.event()], t()}
  def apply(acc, {:block_start, index, kind}) do
    pos = length(acc.message.content)
    block = new_block(kind)
    acc = %{acc | positions: Map.put(acc.positions, index, pos)}
    acc = put_in(acc.message.content, acc.message.content ++ [block])
    {[{start_event(block), pos, acc.message}], acc}
  end

  def apply(acc, {:block_delta, index, chunk}) do
    case fetch(acc, index) do
      {pos, %Text{} = b} ->
        acc = replace(acc, pos, %{b | text: b.text <> chunk})
        {[{:text_delta, pos, chunk, acc.message}], acc}

      {pos, %Thinking{} = b} ->
        acc = replace(acc, pos, %{b | thinking: b.thinking <> chunk})
        {[{:thinking_delta, pos, chunk, acc.message}], acc}

      {pos, %ToolCall{}} ->
        acc = %{acc | json: Map.update(acc.json, pos, chunk, &(&1 <> chunk))}
        {[{:toolcall_delta, pos, chunk, acc.message}], acc}

      nil ->
        {[], acc}
    end
  end

  def apply(acc, {:block_signature, index, signature}) do
    case fetch(acc, index) do
      {pos, %Thinking{} = b} ->
        {[], replace(acc, pos, %{b | signature: (b.signature || "") <> signature})}

      _ ->
        {[], acc}
    end
  end

  def apply(acc, {:block_stop, index}) do
    case fetch(acc, index) do
      {pos, %Text{text: text}} ->
        {[{:text_end, pos, text, acc.message}], acc}

      {pos, %Thinking{thinking: thinking}} ->
        {[{:thinking_end, pos, thinking, acc.message}], acc}

      {pos, %ToolCall{} = call} ->
        call = %{call | arguments: decode_arguments(Map.get(acc.json, pos, ""))}
        acc = replace(acc, pos, call)
        {[{:toolcall_end, pos, call, acc.message}], acc}

      nil ->
        {[], acc}
    end
  end

  def apply(acc, {:usage, fields}) do
    {[], put_in(acc.message.usage, struct(acc.message.usage || %Usage{}, fields))}
  end

  def apply(acc, {:stop_reason, reason}) do
    {[], put_in(acc.message.stop_reason, reason)}
  end

  @doc "The terminal event of a successful stream."
  def finish(acc) do
    message = %{acc.message | stop_reason: acc.message.stop_reason || :stop}
    {:done, message.stop_reason, message}
  end

  @doc "The terminal event of a failed or aborted stream; keeps partial content."
  def fail(acc, reason, error_message) when reason in [:error, :aborted] do
    message = %{acc.message | stop_reason: reason, error_message: error_message}
    {:error, reason, message}
  end

  defp new_block(:text), do: %Text{}
  defp new_block(:thinking), do: %Thinking{}
  defp new_block({:tool_call, id, name}), do: %ToolCall{id: id, name: name}

  defp start_event(%Text{}), do: :text_start
  defp start_event(%Thinking{}), do: :thinking_start
  defp start_event(%ToolCall{}), do: :toolcall_start

  defp fetch(acc, index) do
    case Map.fetch(acc.positions, index) do
      {:ok, pos} -> {pos, Enum.at(acc.message.content, pos)}
      :error -> nil
    end
  end

  defp replace(acc, pos, block) do
    put_in(acc.message.content, List.replace_at(acc.message.content, pos, block))
  end

  # A tool call whose JSON is empty or malformed gets empty arguments; schema
  # validation then reports the problem back to the model.
  defp decode_arguments(json) do
    case JSON.decode(json) do
      {:ok, %{} = args} -> args
      _ -> %{}
    end
  end
end
