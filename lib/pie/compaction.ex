defmodule Pie.Compaction do
  @moduledoc """
  Layer 5c: compaction keeps a long session inside the context window without
  losing history.

  When the context gets within `reserve_tokens` of the model's window (or on
  request), the oldest messages are summarized by the model itself and a
  compaction entry is appended to the session, recording the summary and the
  first entry kept verbatim. The projection (`Pie.Session.Context`) then shows
  the model the summary plus the recent messages. The log keeps everything,
  so compaction is reversible by branching from before it.

  The cut keeps roughly `keep_recent_tokens` of recent messages and never
  lands on a tool result, so a tool call and its result stay together.
  Repeated compactions fold the previous summary into the new one.
  """
  alias Pie.AI.{AssistantMessage, Codec, Context, Message, Text, Thinking, ToolCall}
  alias Pie.AI.{ToolResultMessage, Usage, UserMessage}
  alias Pie.Session.Context, as: Projection

  @defaults %{enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000}

  @system "You summarize conversations between a user and an AI coding assistant so that " <>
            "another assistant can continue the work seamlessly. Output only the summary."

  @format """
  Write a structured summary of the conversation above, using exactly these sections:

  ## Goal
  ## Constraints and preferences
  ## Progress
  ### Done
  ### In progress
  ## Key decisions
  ## Next steps
  ## Critical context
  (exact file paths, commands, identifiers and error messages that must not be lost)

  Be concise, but keep every fact needed to continue without the original conversation.
  """

  def defaults, do: @defaults

  @doc """
  Tokens the context occupies: the usage reported with the last successful
  reply, plus an estimate for anything appended after it.
  """
  @spec context_tokens([Message.t()]) :: non_neg_integer()
  def context_tokens(messages) do
    last =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {m, _} ->
        match?(%AssistantMessage{}, m) and m.stop_reason not in [:error, :aborted] and
          Usage.total(m.usage) > 0
      end)

    case last do
      nil ->
        messages |> Enum.map(&estimate/1) |> Enum.sum()

      {m, i} ->
        Usage.total(m.usage) +
          (messages |> Enum.drop(i + 1) |> Enum.map(&estimate/1) |> Enum.sum())
    end
  end

  @spec due?([Message.t()], Pie.AI.Model.t(), map()) :: boolean()
  def due?(messages, model, settings) do
    settings.enabled and context_tokens(messages) > model.context_window - settings.reserve_tokens
  end

  @doc "A rough token estimate (4 characters per token)."
  def estimate(%{content: content}) do
    chars =
      Enum.reduce(content, 0, fn
        %Text{text: t}, acc -> acc + byte_size(t)
        %Thinking{thinking: t}, acc -> acc + byte_size(t)
        %ToolCall{name: n, arguments: a}, acc -> acc + byte_size(n) + byte_size(JSON.encode!(a))
        _, acc -> acc
      end)

    div(chars, 4)
  end

  @doc """
  Plans and summarizes a compaction of the branch `path`. Returns
  `{:ok, %{summary, first_kept_id, tokens_before}}`, `:noop` when there is
  nothing old enough to summarize, or `{:error, reason}`.
  """
  def run(path, model, settings, opts \\ [], instructions \\ nil) do
    {previous, kept} = Projection.project(path)

    case cut(kept, settings.keep_recent_tokens) do
      nil ->
        :noop

      index ->
        {old, [first_kept | _]} = Enum.split(kept, index)
        messages = Enum.map(old, &Codec.decode(&1["message"]))
        tokens_before = path |> Projection.messages() |> context_tokens()

        with {:ok, summary} <-
               summarize(messages, previous && previous["summary"], model, opts, instructions) do
          {:ok,
           %{summary: summary, first_kept_id: first_kept["id"], tokens_before: tokens_before}}
        end
    end
  end

  # The largest index whose suffix holds at least keep_recent tokens, moved
  # back past tool results; nil when everything fits or nothing precedes it.
  defp cut(entries, keep_recent) do
    tokens = Enum.map(entries, &estimate(Codec.decode(&1["message"])))
    suffix_sums = tokens |> Enum.reverse() |> Enum.scan(&+/2) |> Enum.reverse()

    case suffix_sums
         |> Enum.with_index()
         |> Enum.filter(fn {sum, _} -> sum >= keep_recent end)
         |> List.last() do
      nil -> nil
      {_, index} -> valid_cut(entries, index)
    end
  end

  defp valid_cut(_entries, 0), do: nil

  defp valid_cut(entries, index) do
    if Enum.at(entries, index)["message"]["role"] == "toolResult",
      do: valid_cut(entries, index - 1),
      else: index
  end

  defp summarize(messages, previous, model, opts, instructions) do
    prompt =
      IO.iodata_to_binary([
        "<conversation>\n",
        Enum.map_join(messages, "\n\n", &serialize/1),
        "\n</conversation>\n\n",
        if(previous,
          do: [
            "<previous-summary>\n",
            previous,
            "\n</previous-summary>\n\n",
            "The previous summary covers what came before the conversation above; merge both.\n\n"
          ],
          else: []
        ),
        @format,
        if(instructions, do: ["\nFocus especially on: ", instructions], else: [])
      ])

    case Pie.AI.complete(
           model,
           %Context{system_prompt: @system, messages: [UserMessage.new(prompt)]},
           opts
         ) do
      %AssistantMessage{stop_reason: r} = m when r in [:stop, :length] -> {:ok, Message.text(m)}
      %AssistantMessage{error_message: error} -> {:error, error}
    end
  end

  # Serialized as text so the summarizer reads the conversation instead of continuing it.
  defp serialize(%UserMessage{} = m), do: "[User]: " <> Message.text(m)

  defp serialize(%AssistantMessage{content: content}) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} -> ["[Assistant]: " <> t]
      %ToolCall{name: n, arguments: a} -> ["[Assistant tool call]: #{n}(#{JSON.encode!(a)})"]
      %Thinking{} -> []
    end)
    |> Enum.join("\n")
  end

  defp serialize(%ToolResultMessage{} = m) do
    label = if m.is_error, do: "[Tool error]: ", else: "[Tool result]: "
    text = Message.text(m)

    label <>
      if(String.length(text) > 2_000,
        do: String.slice(text, 0, 2_000) <> " …[truncated]",
        else: text
      )
  end
end
