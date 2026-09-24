defmodule Pie.AI.Provider do
  @moduledoc """
  A provider turns a context into a lazy stream of typed events (see `Pie.AI`).

  The contract every provider must honour:

    * the first event is `{:start, partial}`;
    * the last event is `{:done, reason, message}` or
      `{:error, reason, message}`, and failures (HTTP errors, bad keys,
      malformed streams) are reported that way, never raised;
    * if `opts[:signal]` is a reference, receiving `{:abort, signal}` in the
      consuming process ends the stream with `{:error, :aborted, message}`
      carrying whatever content had arrived so far.

  Providers translate wire formats into the neutral deltas understood by
  `Pie.AI.Accumulator`; they never build typed events themselves.
  """

  @callback stream(Pie.AI.Model.t(), Pie.AI.Context.t(), keyword()) :: Enumerable.t()
end
