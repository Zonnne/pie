defmodule Pie.AI.Providers.Faux do
  @moduledoc """
  A scripted provider for tests and offline use.

  `model.options.responder` is a function from `Pie.AI.Context` to a response:

      "some text"                                    # a text reply
      [{:thinking, "..."}, {:text, "..."}, {:tool_call, "read", %{"path" => "x"}}]
      {:error, "message"}                            # a provider failure

  `model.options.delay` (milliseconds) paces the deltas so streams can be
  watched and aborted. It speaks the same neutral deltas as real providers,
  so everything above it cannot tell the difference.
  """
  @behaviour Pie.AI.Provider

  alias Pie.AI.{Accumulator, Message}

  @impl true
  def stream(model, context, opts) do
    signal = opts[:signal] || make_ref()
    delay = Map.get(model.options, :delay, 0)
    responder = Map.get(model.options, :responder, &echo/1)

    Stream.resource(
      fn -> {:start, Accumulator.new(model), deltas(responder.(context), context)} end,
      fn
        {:start, acc, deltas} -> {[Accumulator.start(acc)], {:streaming, acc, deltas}}
        {:streaming, acc, deltas} -> step(acc, deltas, signal, delay)
        {:halted, _, _} = s -> {:halt, s}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  A responder that replays `responses` in order. Each response may also be a
  function of the context, so tests can assert on what the model was shown.
  """
  def sequence(responses) do
    {:ok, pid} = Agent.start_link(fn -> responses end)

    fn context ->
      case Agent.get_and_update(pid, fn
             [] -> {:exhausted, []}
             [r | rest] -> {r, rest}
           end) do
        :exhausted -> {:error, "faux script exhausted"}
        fun when is_function(fun, 1) -> fun.(context)
        response -> response
      end
    end
  end

  @doc "The default responder: repeats the last user message."
  def echo(context) do
    last = context.messages |> Enum.filter(&match?(%Pie.AI.UserMessage{}, &1)) |> List.last()
    "You said: " <> if(last, do: Message.text(last), else: "nothing")
  end

  defp step(acc, deltas, signal, delay) do
    receive do
      {:abort, ^signal} ->
        {[Accumulator.fail(acc, :aborted, "Request aborted")], {:halted, acc, []}}
    after
      delay -> emit(acc, deltas)
    end
  end

  defp emit(acc, [:finish | _]), do: {[Accumulator.finish(acc)], {:halted, acc, []}}

  defp emit(acc, [{:fail, msg} | _]),
    do: {[Accumulator.fail(acc, :error, msg)], {:halted, acc, []}}

  defp emit(acc, [delta | rest]) do
    {events, acc} = Accumulator.apply(acc, delta)
    {events, {:streaming, acc, rest}}
  end

  defp deltas({:error, message}, _context), do: [{:fail, message}]
  defp deltas(text, context) when is_binary(text), do: deltas([{:text, text}], context)

  defp deltas(parts, context) when is_list(parts) do
    blocks = parts |> Enum.with_index() |> Enum.flat_map(fn {part, i} -> part(part, i) end)
    stop = if Enum.any?(parts, &match?({:tool_call, _, _}, &1)), do: :tool_use, else: :stop
    blocks ++ [{:usage, usage(context, parts)}, {:stop_reason, stop}, :finish]
  end

  defp part({:text, text}, i),
    do: [{:block_start, i, :text}] ++ chunks(text, i) ++ [{:block_stop, i}]

  defp part({:thinking, text}, i) do
    [{:block_start, i, :thinking}] ++
      chunks(text, i) ++ [{:block_signature, i, "faux"}, {:block_stop, i}]
  end

  defp part({:tool_call, name, args}, i) do
    id = "faux_#{System.unique_integer([:positive])}"

    [
      {:block_start, i, {:tool_call, id, name}},
      {:block_delta, i, JSON.encode!(args)},
      {:block_stop, i}
    ]
  end

  defp chunks(text, i) do
    for chunk <- Regex.split(~r/(?<=\s)/, text), chunk != "", do: {:block_delta, i, chunk}
  end

  # Rough token counts (4 chars per token) so context accounting works offline.
  defp usage(context, parts) do
    input = context.messages |> Enum.map(&inspect(&1.content)) |> Enum.join() |> byte_size()
    output = parts |> inspect() |> byte_size()
    %{input: div(input + byte_size(context.system_prompt || ""), 4), output: div(output, 4)}
  end
end
