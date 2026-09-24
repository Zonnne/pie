# Decision log

Key decisions made while building pie, in the order they were made. Each
entry records the context, the decision, and what it costs us. Entries are
append-only: a later entry may supersede an earlier one, but never rewrites it.

---

## D-001 · Build in Pi's order, one layer per commit

**Context.** The guiding note for this project:

> If I were building a coding agent from scratch, I would follow the same
> order: start with a typed model stream, implement the smallest correct tool
> loop, make every lifecycle transition observable, persist sessions
> independently from context, and only then add prompts, extensions,
> compaction, skills, and user interfaces.

**Decision.** The git history follows that order exactly. Each layer only
depends on the layers below it, and each commit leaves a working, tested
system.

**Consequences.** Layers can be read (and reviewed) bottom-up. Some modules
grow across commits (e.g. the application supervision tree gains children as
layers appear) instead of being written once up front.

---

## D-002 · Zero dependencies

**Context.** Pi keeps its dependency surface small. A minimal agent should be
readable end to end without opening `deps/`. Elixir 1.18 ships a `JSON`
module; OTP ships an HTTP client (`:httpc`), TLS (`:ssl`) and the OS
certificate store (`:public_key.cacerts_get/0`).

**Decision.** No Hex dependencies at all. Require Elixir ~> 1.18 (works on
OTP 25+). HTTP streaming uses `:httpc` in async mode (`stream: :self`), which
delivers body chunks as messages to the consuming process.

**Consequences.** `:httpc` is less ergonomic than Req/Finch (charlist URLs and
headers, no HTTP/2, no connection pooling to speak of) and does not read
`HTTPS_PROXY` on its own. For one streaming request at a time none of that
matters. Tests use a hand-written TCP server (`test/support/sse_server.ex`)
instead of a mocking library, which also means the real HTTP path is tested.

---

## D-003 · The typed stream is a lazy `Stream` of tagged tuples; errors are events

**Context.** Pi's `pi-ai` returns an async iterable of typed events and never
throws: HTTP failures, bad keys and aborts all arrive as a final `error` event
carrying a partial assistant message. The closest BEAM equivalent of an async
iterable is a lazy `Stream` consumed in the caller's process.

**Decision.** `Pie.AI.stream/3` returns `Stream.resource/3`. Events are tagged
tuples (`{:text_delta, index, delta, partial}`, `{:done, reason, message}`,
...) so consumers pattern-match on them. Every event carries the partial
message as its last element. Every stream ends with exactly one `:done` or
`:error` event, and providers must never raise.

**Consequences.** The HTTP request lives exactly as long as the consumer:
halting early runs the resource's `after` function, which cancels the
request. Tuples are cheap to match but not self-describing, so `Pie.AI`
documents the full event vocabulary in one place. Carrying the partial in
every event costs copying when events cross process boundaries (the agent
forwards them to subscribers). We accept that for simplicity; the fix would be
to strip partials from forwarded deltas.

---

## D-004 · Providers emit neutral deltas; one accumulator builds typed events

**Context.** In Pi each provider builds its own partial messages and events.
Doing that per provider duplicates the trickiest logic (index bookkeeping,
tool-call JSON buffering, signatures).

**Decision.** Providers only translate their wire format into six neutral
deltas (`{:block_start, i, kind}`, `{:block_delta, i, bin}`,
`{:block_signature, i, sig}`, `{:block_stop, i}`, `{:usage, map}`,
`{:stop_reason, r}`). `Pie.AI.Accumulator`, a pure module, folds deltas into
typed events and the partial message. The Anthropic provider is about 150
lines of mostly wire mapping. The `Faux` provider emits the same deltas, so
tests exercise the same accumulator as production.

**Consequences.** Tool-call arguments are decoded once, at `block_stop`. We
don't parse partial JSON while it streams (Pi does, for live UI previews).
Malformed argument JSON decodes to `%{}`, and schema validation reports it
back to the model.

---

## D-005 · Abort is a message: a signal is a reference

**Context.** Pi threads an `AbortSignal` through every async call. On the BEAM
the natural cancellation primitives are messages and process exits.

**Decision.** A signal is a plain reference. Aborting means sending
`{:abort, ref}` to the process consuming the stream. Providers wait for it in
the same `receive` that waits for HTTP chunks, so an abort is noticed
immediately, and if it arrives early it waits in the mailbox until the next
receive. The aborted stream still ends with a proper `{:error, :aborted,
partial}` event.

**Consequences.** Cancellation is cooperative at the model layer, and it
works even when the abort arrives before the request starts. Side-effecting
work (tools) is cancelled differently, by killing processes (see D-010).

---

## D-006 · No model catalog; the model id is configuration

**Context.** Pi generates a large catalog of models, prices and limits. It is
useful, but it goes stale and is a lot of surface for a minimal agent.

**Decision.** `Pie.AI.Model` is a small struct (`provider`, `id`, `base_url`,
`context_window`, `max_tokens`, `options`) built from configuration.
`provider` is a registered name or any module implementing
`Pie.AI.Provider`, so adding a provider needs no registry change. The CLI
requires `--model`/`PIE_MODEL`; no model id is hard-coded.

**Consequences.** No cost accounting (we track token usage, not dollars). The
context window defaults to 200k and can be overridden with
`PIE_CONTEXT_WINDOW` for compaction thresholds.

---

## D-007 · Replayed history is normalized, never trusted

**Context.** Append-only histories keep the scars of real runs: aborted
replies with half-streamed tool calls, errored turns, crashes between a tool
call and its result. Providers reject such histories with a 400.

**Decision.** `Pie.AI.Transform.normalize/1` runs before every request. It
drops assistant messages that ended in `:error`/`:aborted`, inserts a
synthetic error result for every tool call that never got one, and drops
results whose call is gone. Pi does the same in `transformMessages`.

**Consequences.** The log stays complete and honest, and only the projection
sent to the model is cleaned. A crash can never poison a session.

---

## D-008 · The loop is a plain function; the runtime owns the process

**Context.** Pi's `agentLoop` is a function over a context and a config
(`convertToLlm`, `transformContext`, `getSteeringMessages`, ...), separate
from the stateful `Agent` class that runs it.

**Decision.** `Pie.Agent.Loop.run(prompts, history, config)` is a plain,
synchronous function that returns the messages it added. It touches the
outside world only through `Config` callbacks: `emit`, `steering`,
`follow_up`, `before_tool_call`, `transform_context`. It doesn't know whether
it runs in a test process, a `Task`, or an agent.

**Consequences.** Tests exercise it directly with the Faux provider. Layer 3
supplies callbacks that talk to a GenServer, and the loop's code doesn't
change. The loop keeps its own copy of the history for the length of a run,
so the runtime must never change history mid-run (compaction only happens
while idle).

---

## D-009 · Every tool call gets exactly one result, committed in call order

**Context.** A tool call without a result makes the next request invalid, and
real runs produce every failure mode: unknown tools, bad arguments, raises,
hangs, aborts.

**Decision.** The scheduler guarantees one `ToolResultMessage` per call,
whatever happens: success, validation failure, a gate block, a crash, a
timeout, an abort (running calls are killed, queued ones are marked
skipped). Results are appended in call order after the batch finishes, while
`tool_execution_*` events stream live in completion order.

**Consequences.** Session logs are deterministic regardless of scheduling. A
result is persisted only when its whole batch completes. A crash mid-batch
loses the finished results of that batch, and D-007 then fills them in as
interrupted.

---

## D-010 · A process per tool call; cancellation by killing processes

**Context.** Pi passes an `AbortSignal` into every tool and trusts it to be
honoured. On the BEAM, a process that should stop can simply be killed, and
supervision gives isolation for free.

**Decision.** Each call runs in its own process under `Pie.TaskSupervisor`,
linked to the loop, and the loop traps exits:

* a tool that raises only kills its own process → error result;
* timeout → `Task.shutdown(task, :brutal_kill)` → error result;
* abort → the loop kills every running tool;
* if the loop dies, its linked tools die with it; if the loop's parent (the
  agent) dies, the loop sees `{:EXIT, parent, _}` and exits.

OS processes are the one thing links cannot reach. The bash tool therefore
starts a tiny guard process that monitors the tool process and kills the
command's process group when the tool process dies. OTP already starts port
programs in their own session (`erl_child_setup` calls `setsid`), so the OS
pid is the process-group id. Our first attempt wrapped commands in
`setsid(1)`, which forked and hid the exit status; tests caught it.

Parallelism: tools marked `parallel: true` (read) may run concurrently, up to
`max_concurrency`. Any other tool acts as a barrier: it waits for everything
running to finish, then runs alone. Reads fan out; writes and shell commands
keep their order.

**Consequences.** Tool authors write straight-line code with no cancellation
checks. The scheduler is a hand-written receive loop (~150 lines), not
`Task.async_stream`, because it must also react to aborts, timeouts and
progress messages. It unlinks finished tasks and flushes their exit and
timer messages so the loop's mailbox stays clean.

---

## D-011 · Validate a small subset of JSON Schema, and report errors to the model

**Context.** Pi validates tool arguments with TypeBox + AJV. Without
dependencies we would have to write a validator ourselves.

**Decision.** `Pie.Tool.validate/2` checks required properties and primitive
types (`string`, `integer`, `number`, `boolean`, `array`, `object`), which is
where models actually go wrong. Violations become an error result naming the
problem, and the model retries. There is no type coercion.

**Consequences.** Nested schemas, enums and formats aren't enforced; tools
must still pattern-match defensively on what they need.

---

## D-012 · Four tools, like Pi, with output budgets

**Decision.** `read`, `bash`, `edit`, `write`, and nothing else; `ls`, `grep`,
`find` and git go through bash. `read` pages at 2000 lines / 50KB and tells
the model how to continue. `bash` keeps the *last* 2000 lines / 50KB, because
the end of command output is what matters, and streams its output tail as
updates every 250ms. `edit` requires an exact, unique match of `oldText`.

**Consequences.** No image support in `read` (non-UTF-8 files are rejected),
and no fuzzy matching in `edit`.

---

## D-002 addendum · Two `:httpc` streaming quirks, found by repeating tests

Running the suite in a loop exposed two behaviours of `:httpc`'s async
streaming mode, both confirmed in OTP's source:

1. Body bytes that arrive in the same TCP read as the response headers are
   not delivered until the next packet (`httpc_handler:handle_http_body/2`
   stores the decoder continuation without streaming what it already
   decoded). Against the real API this can delay the first event by one
   packet gap, which is harmless for token streams. The test server sends
   headers separately so abort tests are deterministic.
2. An empty `{:stream, ""}` part may precede `:stream_end`. The provider
   drains every message for the request, of any shape, before ending the
   stream, so nothing is left in the consumer's mailbox.

---

## D-013 · The agent is a GenServer and the only source of truth

**Context.** Pi's `Agent` class holds state (`messages`, `isStreaming`,
`streamMessage`, `pendingToolCalls`) and re-emits loop events to listeners
after updating that state.

**Decision.** `Pie.Agent` is a GenServer that runs at most one loop at a time,
in a task. The loop reports events as messages tagged with a run id. The
agent applies each event to its state, then broadcasts it. A subscriber that
receives `{:message_end, m}` can rely on `m` already being in the agent's
state. Events whose run id is not the current run (an aborted or crashed
run's leftovers) are dropped.

**Consequences.** One mailbox serializes everything: prompts, queue changes,
events, snapshots. There are no locks and no torn reads. The loop keeps a
private copy of the history for the run (D-008), so the agent's copy and the
loop's copy are reconciled by `message_end` events, not by sharing.

---

## D-014 · Pub/sub is a `Registry` with duplicate keys, keyed by agent id

**Decision.** `Pie.PubSub` is a duplicate-key `Registry`. Subscribing
registers the caller under `{:events, agent_id}`, and the agent broadcasts
with `Registry.dispatch/3`. Agents are also named through a unique `Registry`
(`{:agent, id}`), so callers address them by id.

**Consequences.** A subscription belongs to the subscriber, not to the agent
process, so it survives agent restarts (tested). Subscriptions are cleaned
up automatically when subscribers die. Delivery is local to the node, which
is all a CLI agent needs; `:pg` would be the drop-in for a cluster.

---

## D-015 · Steering and follow-up queues live in the agent; delivery is at turn boundaries

**Context.** Pi lets users *steer* a running agent (a message delivered
mid-run) and queue *follow-ups* (delivered when it would stop). Pi runs tools
one at a time and skips the remaining ones when a steering message arrives.

**Decision.** The agent owns both queues. The loop dequeues them with a
synchronous call at turn boundaries. Steering is delivered after the
current tool batch completes, which means we never kill a running tool to
make room for a steering message. Follow-ups are delivered when a turn ends
without tool calls. All queued messages are delivered together. A message
queued after the loop's last check starts a new run as soon as the current
one ends, so nothing is ever stranded. `abort/1` clears both queues.
`steer/2` and `follow_up/2` on an idle agent simply start a run.

**Consequences.** Steering is less immediate than Pi's when a batch contains
a slow tool; in exchange, a tool's side effects are never cut short by a
user message, only by an explicit abort.

---

## D-016 · Runs are linked to their agent; the agent traps exits

**Decision.** The loop task is started with `Task.Supervisor.async/2`
(linked + monitored) and the agent traps exits. If the agent dies, the linked
run (and its linked tools, D-010) die too; if the run crashes, the agent gets
a `:DOWN`, broadcasts `{:run_crashed, reason}`, records the error and returns
to idle. `terminate/2` kills the run on orderly shutdown. The agents'
`DynamicSupervisor` tolerates many restarts, because agents are independent
and one crashing in a loop must not take down the rest.

**Consequences.** There are no orphaned runs and no zombie tools after a
crash, and it takes no bookkeeping, only links. A crash in projection or
provider code costs one run, not the conversation (tested with a
`transform_context` that raises).
