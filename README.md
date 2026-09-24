# pie

A minimal rewrite of [Pi](https://github.com/badlogic/pi-mono), the coding
agent, in Elixir, built on OTP.

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

pie is built in exactly that order, one layer per commit (see
[DECISIONS.md](DECISIONS.md) for the reasoning behind each step).

| # | Layer | Modules |
|---|-------|---------|
| 1 | Typed model stream | `Pie.AI`, `Pie.AI.Accumulator`, `Pie.AI.Providers.*` |
