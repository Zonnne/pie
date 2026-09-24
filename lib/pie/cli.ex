defmodule Pie.CLI do
  @moduledoc """
  Layer 5e: the interface, and the only part that knows about a terminal.

  Three modes over the same agent:

    * interactive (default): a reader process turns stdin lines into
      messages while this process renders the agent's events as they come.
      Typing while the agent works steers it; EOF waits for the agent to
      finish, then exits (so `echo "task" | pie` works).
    * `--print`: run one prompt, print the final answer, exit.
    * `--mode json`: run one prompt, print every lifecycle event as a JSON
      line, exit. It is layer 3 made visible, and scriptable.

  Everything interesting happens in the layers below; this module only wires
  them together from flags and environment variables.
  """
  alias Pie.AI.{AssistantMessage, Model, Text}

  @switches [
    model: :string,
    provider: :string,
    continue: :boolean,
    session: :string,
    no_session: :boolean,
    print: :boolean,
    mode: :string,
    thinking: :integer,
    help: :boolean
  ]
  @aliases [m: :model, c: :continue, p: :print, h: :help]

  @commands """
  Commands:
    /abort            stop the current run (the partial reply is kept)
    /compact [focus]  summarize older history to free context
    /follow <text>    queue a message for when the agent finishes
    /session          show the session file and context size
    /help             show this help
    /quit             exit immediately
  Typing while the agent works steers it: the message is delivered after the
  current tool calls finish.
  """

  @usage """
  pie: a minimal coding agent

  Usage: pie [options] [prompt]

    -m, --model ID        model id (default: $PIE_MODEL)
        --provider NAME   anthropic (default) or faux (offline echo)
    -c, --continue        continue the most recent session in this directory
        --session PATH    open or create a specific session file
        --no-session      keep the session in memory only
    -p, --print           run the prompt, print the final answer and exit
        --mode json       run the prompt, print every event as JSON and exit
        --thinking N      extended thinking budget in tokens
    -h, --help

  Environment: ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, PIE_MODEL, PIE_HOME,
  PIE_CONTEXT_WINDOW, PIE_MAX_TOKENS, PIE_DEBUG.

  #{@commands}\
  """

  @doc "Escript entry point."
  def main(argv) do
    Logger.configure(level: if(System.get_env("PIE_DEBUG"), do: :debug, else: :critical))

    status =
      try do
        run(argv)
      rescue
        # stdout closed under us (e.g. `pie --mode json ... | head`): not an error.
        error in ErlangError ->
          if error.original == :terminated, do: 0, else: reraise(error, __STACKTRACE__)
      end

    System.halt(status)
  end

  @doc "Runs the CLI and returns the exit status."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    prompt = Enum.join(words, " ")

    cond do
      opts[:help] ->
        IO.write(@usage)
        0

      invalid != [] ->
        IO.puts(:stderr, "Unknown option: #{invalid |> hd() |> elem(0)}\n\n#{@usage}")
        2

      (opts[:print] || opts[:mode] == "json") and prompt == "" ->
        IO.puts(:stderr, "A prompt is required with --print and --mode json.")
        2

      true ->
        with {:ok, model} <- model(opts),
             {:ok, agent} <- start(opts, model) do
          try do
            cond do
              opts[:mode] == "json" -> json(agent, prompt)
              opts[:print] -> print(agent, prompt)
              true -> interactive(agent, prompt, model)
            end
          after
            Pie.stop_agent(agent)
          end
        else
          {:error, message} ->
            IO.puts(:stderr, message)
            2
        end
    end
  end

  ## Setup

  defp model(opts) do
    case opts[:provider] || System.get_env("PIE_PROVIDER") || "anthropic" do
      "faux" ->
        {:ok, Model.new(:faux, "echo")}

      "anthropic" ->
        case opts[:model] || System.get_env("PIE_MODEL") do
          nil ->
            {:error,
             "No model configured: pass --model <id> or set PIE_MODEL (an Anthropic model id)."}

          id ->
            {:ok,
             Model.new(:anthropic, id,
               context_window: env_int("PIE_CONTEXT_WINDOW", 200_000),
               max_tokens: env_int("PIE_MAX_TOKENS", 16_384)
             )}
        end

      other ->
        {:error, "Unknown provider #{inspect(other)} (expected anthropic or faux)."}
    end
  end

  defp start(opts, model) do
    cwd = File.cwd!()
    tools = Pie.Tools.coding(cwd)
    skills = Pie.Skills.discover(Pie.Skills.default_dirs(cwd))

    result =
      Pie.start_agent(
        model: model,
        cwd: cwd,
        tools: tools,
        system_prompt: Pie.Prompt.build(cwd: cwd, tools: tools, skills: skills),
        session_path: session_path(opts, cwd),
        extensions: load_extensions(cwd),
        stream_opts: if(opts[:thinking], do: [thinking_budget: opts[:thinking]], else: [])
      )

    with {:error, reason} <- result, do: {:error, "Could not start the agent: #{inspect(reason)}"}
  end

  defp session_path(opts, cwd) do
    cond do
      opts[:no_session] -> nil
      opts[:session] -> Path.expand(opts[:session])
      opts[:continue] -> Pie.Session.latest(cwd) || Pie.Session.new_path(cwd)
      true -> Pie.Session.new_path(cwd)
    end
  end

  defp load_extensions(cwd) do
    for dir <- [Path.join(cwd, ".pie/extensions"), Path.join(Pie.home(), "extensions")],
        file <- dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort(),
        {module, _} <- Code.require_file(file) || [],
        Pie.Extension.extension?(module),
        do: module
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} -> n
      _ -> default
    end
  end

  ## Print and JSON modes

  defp print(agent, prompt) do
    :ok = Pie.prompt(agent, prompt)
    Pie.await(agent)

    case Pie.snapshot(agent).messages
         |> Enum.filter(&match?(%AssistantMessage{}, &1))
         |> List.last() do
      %AssistantMessage{stop_reason: reason, error_message: error}
      when reason in [:error, :aborted] ->
        IO.puts(:stderr, "error: #{error}")
        1

      %AssistantMessage{} = reply ->
        IO.puts(Pie.AI.Message.text(reply))
        0
    end
  end

  defp json(agent, prompt) do
    Pie.subscribe(agent)
    :ok = Pie.prompt(agent, prompt)
    notify_when_idle(agent)
    json_loop(agent)
  end

  defp json_loop(agent) do
    receive do
      {:pie_event, ^agent, event} ->
        IO.puts(JSON.encode!(Pie.Agent.Event.to_json(event)))
        json_loop(agent)

      :idle ->
        0
    end
  end

  # A helper process blocks in await/1 so this process can keep rendering.
  defp notify_when_idle(agent) do
    cli = self()

    spawn_link(fn ->
      Pie.await(agent)
      send(cli, :idle)
    end)
  end

  ## Interactive mode

  defp interactive(agent, prompt, model) do
    Pie.subscribe(agent)
    info = Pie.Session.info(Pie.session(agent))

    IO.puts(
      faint("pie · #{model.provider}/#{model.id} · #{info.path || "in-memory session"} · /help")
    )

    cli = self()
    spawn_link(fn -> read_lines(cli) end)

    if prompt != "", do: submit(agent, prompt), else: show_prompt()
    loop(agent)
  end

  defp read_lines(cli) do
    case IO.gets("") do
      line when is_binary(line) ->
        send(cli, {:line, String.trim_trailing(line, "\n")})
        read_lines(cli)

      _eof_or_error ->
        send(cli, :eof)
    end
  end

  defp loop(agent) do
    receive do
      {:pie_event, _, event} ->
        render(event)
        loop(agent)

      {:line, line} ->
        case command(String.trim(line), agent) do
          :quit -> 0
          :ok -> loop(agent)
        end

      :eof ->
        # Finish the current work, then exit.
        notify_when_idle(agent)
        loop(agent)

      :idle ->
        0
    end
  end

  defp command(quit, _agent) when quit in ["/quit", "/exit"], do: :quit
  defp command("", _agent), do: show_prompt()

  defp command("/abort", agent) do
    Pie.abort(agent)
    :ok
  end

  defp command("/compact" <> focus, agent) do
    focus = if String.trim(focus) == "", do: nil, else: String.trim(focus)

    case Pie.compact(agent, focus) do
      :ok -> :ok
      {:error, status} -> note("(busy: #{status})")
    end
  end

  defp command("/follow " <> text, agent) do
    case Pie.follow_up(agent, text) do
      {:ok, :started} -> :ok
      {:ok, :queued} -> IO.puts(faint("(follow-up queued)"))
    end
  end

  defp command("/session", agent) do
    info = Pie.Session.info(Pie.session(agent))
    tokens = Pie.Compaction.context_tokens(Pie.snapshot(agent).messages)

    note("""
    session #{info.id}
      file: #{info.path || "(in memory)"}
      entries: #{info.entries}
      context: ~#{tokens} tokens\
    """)
  end

  defp command("/help", _agent) do
    IO.write(@commands)
    show_prompt()
  end

  defp command("/" <> unknown, _agent), do: note("unknown command /#{unknown} (try /help)")
  defp command(text, agent), do: submit(agent, text)

  defp submit(agent, text) do
    case Pie.steer(agent, text) do
      {:ok, :started} -> :ok
      {:ok, :queued} -> IO.puts(faint("(steering: delivered after the current tool calls)"))
    end

    :ok
  end

  defp show_prompt do
    IO.write(color(:green, "\n› "))
    :ok
  end

  # A dim line of feedback, then the prompt again.
  defp note(text) do
    IO.puts(faint(text))
    show_prompt()
  end

  ## Rendering

  defp render({:message_update, {:text_delta, _, delta, _}}), do: IO.write(delta)
  defp render({:message_update, {:thinking_delta, _, delta, _}}), do: IO.write(faint(delta))
  defp render({:message_update, {:thinking_end, _, _, _}}), do: IO.write("\n")

  defp render({:message_end, %AssistantMessage{stop_reason: :error, error_message: error}}),
    do: IO.puts(color(:red, "\nerror: #{error}"))

  defp render({:message_end, %AssistantMessage{stop_reason: :aborted}}),
    do: IO.puts(color(:yellow, "\n[aborted]"))

  defp render({:message_end, %AssistantMessage{content: content}}) do
    if Enum.any?(content, &match?(%Text{text: t} when t != "", &1)), do: IO.write("\n")
  end

  defp render({:tool_execution_start, call}),
    do: IO.puts(color(:cyan, "▸ #{call.name} #{describe(call)}"))

  defp render({:tool_execution_end, _call, result}) do
    lines = result |> Pie.AI.Message.text() |> String.split("\n")
    shown = Enum.take(lines, 6)
    more = if length(lines) > 6, do: ["… #{length(lines) - 6} more lines"], else: []
    text = Enum.map_join(shown ++ more, "\n", &("  " <> &1))
    IO.puts(if result.is_error, do: color(:red, text), else: faint(text))
  end

  defp render({:agent_end, _}), do: show_prompt()

  defp render({:compaction_start, reason}),
    do: IO.puts(faint("[compacting context (#{reason})…]"))

  defp render({:compaction_end, {:ok, c}}),
    do: note("[compacted ~#{c.tokens_before} tokens into a summary]")

  defp render({:compaction_end, :noop}), do: note("[nothing to compact yet]")

  defp render({:compaction_end, {:error, reason}}) do
    IO.puts(color(:red, "[compaction failed: #{inspect(reason)}]"))
    show_prompt()
  end

  defp render({:run_crashed, reason}) do
    IO.puts(color(:red, "run crashed: #{inspect(reason)}"))
    show_prompt()
  end

  defp render(_other), do: :ok

  defp describe(%{name: "bash", arguments: %{"command" => command}}),
    do: command |> String.split("\n") |> hd() |> truncate(100)

  defp describe(%{arguments: %{"path" => path}}), do: path
  defp describe(%{arguments: args}), do: args |> JSON.encode!() |> truncate(100)

  defp truncate(text, max),
    do: if(String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text)

  defp faint(text), do: color(:faint, text)

  defp color(style, text),
    do: IO.iodata_to_binary(IO.ANSI.format([style, text], IO.ANSI.enabled?()))
end
