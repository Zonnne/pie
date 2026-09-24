# pie

A minimal rewrite of [Pi](https://github.com/badlogic/pi-mono), the coding
agent, in Elixir, with OTP doing the heavy lifting and a few well-chosen
libraries (Req, NimbleOptions, `:telemetry`) doing the chores.

> If I were building a coding agent from scratch, I would follow the same
> order: start with a typed model stream, implement the smallest correct tool
> loop, make every lifecycle transition observable, persist sessions
> independently from context, and only then add prompts, extensions,
> compaction, skills, and user interfaces.
>
> The central lesson is that a production agent is not merely a system prompt
> wrapped around an LLM. It is a concurrent runtime, a tool scheduler, a
> context projection system, a persistence layer, and an interface. Pi remains
> understandable because it lets each of those pieces stay small.

pie was built in exactly that order, one layer per commit, and every key
decision along the way is recorded in **[DECISIONS.md](DECISIONS.md)**.

## Quick start

Requires Elixir ≥ 1.18 (for the built-in `JSON` module) on OTP ≥ 25.

```sh
mix deps.get
mix escript.build                         # produces ./pie (needs Erlang at runtime)

export ANTHROPIC_API_KEY=sk-...
export PIE_MODEL=<an Anthropic model id>  # no model id is hard-coded

./pie                                     # interactive
./pie "explain lib/pie/agent.ex"          # interactive, starting with a prompt
./pie -p "what does mix.exs configure?"   # print the final answer and exit
./pie --mode json "list the tests"        # every lifecycle event as JSON lines
./pie -c                                  # continue the last session in this directory
./pie --provider faux                     # offline: an echo model, no key needed
```

In the interactive UI, typing while the agent works *steers* it (the
message is delivered once the current tool calls finish). Commands:
`/abort`, `/compact [focus]`, `/follow <text>`, `/session`, `/help`, `/quit`.
At EOF pie finishes its current work and exits, so
`echo "fix the build" | ./pie` works.

Sessions are JSONL files under `~/.pie/sessions/<cwd>/` (`PIE_HOME` moves
`~/.pie`). Project instructions come from `AGENTS.md`/`CLAUDE.md` files,
skills from `.pie/skills/*/SKILL.md`, extensions from `.pie/extensions/*.exs`.

## The layers

| # | Layer (in the quote's order) | Modules | The piece it gives you |
|---|------------------------------|---------|------------------------|
| 1 | Typed model stream | `Pie.AI`, `Pie.AI.Accumulator`, `Pie.AI.Providers.{Anthropic,Faux}` | a lazy `Stream` of tagged events; errors are events |
| 2 | Smallest correct tool loop | `Pie.Agent.Loop`, `Pie.Agent.Scheduler`, `Pie.Tool`, `Pie.Tools.*` | **the tool scheduler** |
| 3 | Observable lifecycle | `Pie.Agent`, `Pie.Agent.Event` | **the concurrent runtime** |
| 4 | Sessions independent from context | `Pie.Session`, `Pie.Session.Context`, `Pie.Agent.Supervisor` | **the persistence layer** and **the context projection** |
| 5a | Prompts | `Pie.Prompt` | a small system prompt + AGENTS.md |
| 5b | Extensions | `Pie.Extension`, `Pie.Extension.Server` | tools, prompt amendments, observers, gates |
| 5c | Compaction | `Pie.Compaction` | summaries appended to the log, projected into context |
| 5d | Skills | `Pie.Skills` | progressive disclosure through the read tool |
| 5e | User interface | `Pie.CLI` | **the interface**: interactive, print and JSON modes |

`git log --reverse` walks the same path.

## How OTP maps onto an agent

| Agent concern | OTP feature | Where |
|---|---|---|
| Streaming a model reply | `Stream.resource/3` over Req's `into: :self` messages; halting cancels the request | `Pie.AI.Providers.Anthropic` |
| Abort signal | a reference; aborting = sending `{:abort, ref}` to the consumer | `Pie.AI`, `Pie.Agent.Scheduler` |
| One conversation's state | a `GenServer`: one mailbox serializes prompts, events and queries | `Pie.Agent` |
| Running a turn | a `Task` linked to its agent; the agent traps exits | `Pie.Agent` |
| Tool isolation, timeouts, cancellation | one process per tool call; kill it to cancel | `Pie.Agent.Scheduler` |
| Killing shell commands | a port-owning runner that monitors the tool process and kills the OS process group | `Pie.Tools.Bash` |
| Observability | `Registry` with duplicate keys as pub/sub; subscriptions outlive agent restarts | `Pie.Agent` |
| Crash recovery | per-agent `:rest_for_one` tree: session → extensions → agent | `Pie.Agent.Supervisor` |
| Durable log | one process owns one append-only file | `Pie.Session` |
| Plugins | supervised extension processes + runtime code loading (`Code.require_file/1`) | `Pie.Extension` |
| Metrics and tracing | `:telemetry` spans for runs, turns, tools and compactions | `Pie.Telemetry` |

The supervision tree:

```
Pie.Supervisor
├── Pie.Registry          (unique)     agents, sessions and trees by id
├── Pie.PubSub            (duplicate)  event subscriptions, extension lookup
├── Pie.TaskSupervisor                 loop runs, tool calls, compactions
└── Pie.AgentSupervisor   (dynamic)
    └── Pie.Agent.Supervisor  (rest_for_one, one per agent)
        ├── Pie.Session
        ├── extensions (one_for_one) ── Pie.Extension.Server …
        └── Pie.Agent ─ ─ linked ─ ─ loop task ─ ─ linked ─ ─ tool tasks
```

## As a library

```elixir
model = Pie.AI.Model.new(:anthropic, System.fetch_env!("PIE_MODEL"))
cwd = File.cwd!()
tools = Pie.Tools.coding(cwd)

{:ok, agent} =
  Pie.start_agent(
    model: model,
    tools: tools,
    system_prompt: Pie.Prompt.build(cwd: cwd, tools: tools),
    session_path: Pie.Session.new_path(cwd),
    extensions: [{ProtectedPaths, patterns: [".env"]}]
  )

Pie.subscribe(agent)                       # {:pie_event, agent, event} messages
Pie.Telemetry.attach_default_logger()      # or attach your own :telemetry handlers
:ok = Pie.prompt(agent, "Run the tests and fix what fails")
{:ok, :queued} = Pie.steer(agent, "Only touch lib/")
Pie.await(agent)
```

Or one layer down, with no processes of your own:

```elixir
Pie.AI.stream(model, %Pie.AI.Context{messages: [Pie.AI.UserMessage.new("hi")]})
|> Enum.each(fn
  {:text_delta, _index, delta, _partial} -> IO.write(delta)
  _event -> :ok
end)
```

Options are validated by a NimbleOptions schema: a typo such as `tols:`
raises immediately, and `h Pie.start_agent` lists every option with its
default.

## Libraries

| Library | Why |
|---|---|
| [Req](https://hex.pm/packages/req) | HTTP streaming, pooling, proxies and retries of 429/5xx/529; `stream_opts: [req_options: ...]` passes anything through |
| [NimbleOptions](https://hex.pm/packages/nimble_options) | validates and documents `Pie.start_agent/1` options |
| [telemetry](https://hex.pm/packages/telemetry) | standard span events for existing metrics and tracing tooling |

## Extending

* **Tools** are data: `%Pie.Tool{name:, description:, parameters: json_schema,
  execute: fn args, ctx -> {:ok, text} end}`. Set `parallel: true` for
  read-only tools that can run concurrently.
* **Extensions** implement any of `init/1`, `tools/1`, `system_prompt/2`,
  `handle_event/2`, `before_tool_call/2`. See
  [`examples/extensions/protected_paths.exs`](examples/extensions/protected_paths.exs).
* **Skills** are `SKILL.md` files with `name`/`description` frontmatter.
* **Providers** implement `Pie.AI.Provider.stream/3` by emitting six neutral
  deltas. Pass the module itself as the model's `provider`.

## Tests

```sh
mix test                               # ~60 tests, about a second
mix test --repeat-until-failure 200    # how the concurrency bugs were shaken out
```

The `Faux` provider scripts model replies (and can assert on the context it is
shown); `test/support/sse_server.ex` is a real HTTP server, so the HTTP
streaming path, aborts included, is tested end to end, up to a CLI run that
makes a real bash tool call.

## What is deliberately missing

Compared with Pi: other providers (OpenAI, Google, …), images, OAuth logins,
model switching mid-session, prompt templates, a full TUI,
extension commands and UI widgets, split-turn compaction and branch
summaries. Each omission is noted in the decision that caused it.
