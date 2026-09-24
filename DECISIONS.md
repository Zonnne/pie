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
