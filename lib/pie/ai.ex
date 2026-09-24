defmodule Pie.AI do
  @moduledoc """
  Layer 1: a typed model stream.

  `stream/3` returns a lazy `Stream` of tagged tuples. Every event carries
  the partial `Pie.AI.AssistantMessage` built so far as its last element, so
  consumers can render without keeping their own state:

      {:start, partial}
      {:text_start, index, partial}
      {:text_delta, index, delta, partial}
      {:text_end, index, text, partial}
      {:thinking_start, index, partial}
      {:thinking_delta, index, delta, partial}
      {:thinking_end, index, thinking, partial}
      {:toolcall_start, index, partial}
      {:toolcall_delta, index, json_chunk, partial}
      {:toolcall_end, index, %Pie.AI.ToolCall{}, partial}
      {:done, :stop | :length | :tool_use, message}
      {:error, :error | :aborted, message}

  A stream always ends with exactly one `:done` or `:error` event. Errors are
  data, so callers never need `try`. Pass `signal: ref` and send
  `{:abort, ref}` to the consuming process to abort, the BEAM equivalent of
  an `AbortSignal`.
  """
  alias Pie.AI.{AssistantMessage, Context, Model}

  @type partial :: AssistantMessage.t()
  @type event ::
          {:start, partial}
          | {:text_start | :thinking_start | :toolcall_start, non_neg_integer(), partial}
          | {:text_delta | :thinking_delta | :toolcall_delta, non_neg_integer(), binary(),
             partial}
          | {:text_end | :thinking_end, non_neg_integer(), binary(), partial}
          | {:toolcall_end, non_neg_integer(), Pie.AI.ToolCall.t(), partial}
          | {:done, :stop | :length | :tool_use, AssistantMessage.t()}
          | {:error, :error | :aborted, AssistantMessage.t()}

  @providers %{anthropic: Pie.AI.Providers.Anthropic, faux: Pie.AI.Providers.Faux}

  @doc "Streams a reply from `model` for `context`."
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    provider!(model.provider).stream(model, context, opts)
  end

  @doc "Runs a stream to completion and returns the final message."
  @spec complete(Model.t(), Context.t(), keyword()) :: AssistantMessage.t()
  def complete(model, context, opts \\ []) do
    model
    |> stream(context, opts)
    |> Enum.reduce(nil, fn
      {:done, _, message}, _ -> message
      {:error, _, message}, _ -> message
      _event, acc -> acc
    end)
  end

  @doc "The partial (or final) message carried by any event."
  @spec partial(event()) :: AssistantMessage.t()
  def partial(event), do: elem(event, tuple_size(event) - 1)

  @doc "Resolves a provider name (or a module implementing `Pie.AI.Provider`)."
  def provider!(name) do
    cond do
      Map.has_key?(@providers, name) -> Map.fetch!(@providers, name)
      is_atom(name) and Code.ensure_loaded?(name) and function_exported?(name, :stream, 3) -> name
      true -> raise ArgumentError, "unknown provider #{inspect(name)}"
    end
  end
end
