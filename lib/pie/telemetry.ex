defmodule Pie.Telemetry do
  @moduledoc """
  `:telemetry` spans for the agent lifecycle, so metrics, logging and tracing
  tools can attach without writing an event subscriber.

  Every span emits `start` (measurements `:system_time`, `:monotonic_time`)
  and `stop` (measurements `:duration`, `:monotonic_time`, in native time
  units) events. Metadata always includes `:agent_id`.

  | Event | Extra metadata | Extra `stop` measurements |
  |---|---|---|
  | `[:pie, :run, :start \\| :stop \\| :exception]` | `:reason` on exception | `:messages` |
  | `[:pie, :turn, :start \\| :stop]` | `:stop_reason`, `:tool_calls` | `:input_tokens`, `:output_tokens`, `:cache_read_tokens`, `:cache_write_tokens` |
  | `[:pie, :tool, :start \\| :stop]` | `:tool_name`, `:tool_call_id`, `:is_error` (stop) | |
  | `[:pie, :compaction, :start \\| :stop]` | `:reason` (start), `:result` (stop) | `:tokens_before` |

  The agent calls `handle/3` for every event it broadcasts; span start times
  are kept in the agent's state, so a restarted agent simply starts fresh.

      Pie.Telemetry.attach_default_logger()   # log spans at :debug
  """
  require Logger

  alias Pie.AI.Usage

  @events for span <- [:run, :turn, :tool, :compaction],
              kind <- [:start, :stop],
              do: [:pie, span, kind]
  @events @events ++ [[:pie, :run, :exception]]

  @doc "Every event name this module emits."
  def events, do: @events

  @doc "Emits telemetry for one lifecycle event. Returns the updated span timers."
  @spec handle(map(), String.t(), term()) :: map()
  def handle(timers, agent_id, event) do
    meta = %{agent_id: agent_id}

    case event do
      :agent_start ->
        start(timers, :run, [:pie, :run], meta)

      {:agent_end, messages} ->
        stop(timers, :run, [:pie, :run], %{messages: length(messages)}, meta)

      {:run_crashed, reason} ->
        stop(timers, :run, [:pie, :run], %{}, Map.put(meta, :reason, reason), :exception)

      :turn_start ->
        start(timers, :turn, [:pie, :turn], meta)

      {:turn_end, message, results} ->
        usage = message.usage || %Usage{}

        measurements = %{
          input_tokens: usage.input,
          output_tokens: usage.output,
          cache_read_tokens: usage.cache_read,
          cache_write_tokens: usage.cache_write
        }

        meta = Map.merge(meta, %{stop_reason: message.stop_reason, tool_calls: length(results)})
        stop(timers, :turn, [:pie, :turn], measurements, meta)

      {:tool_execution_start, call} ->
        start(timers, {:tool, call.id}, [:pie, :tool], tool_meta(meta, call))

      {:tool_execution_end, call, result} ->
        meta = meta |> tool_meta(call) |> Map.put(:is_error, result.is_error)
        stop(timers, {:tool, call.id}, [:pie, :tool], %{}, meta)

      {:compaction_start, reason} ->
        start(timers, :compaction, [:pie, :compaction], Map.put(meta, :reason, reason))

      {:compaction_end, result} ->
        {outcome, measurements} =
          case result do
            {:ok, c} -> {:ok, %{tokens_before: c.tokens_before}}
            :noop -> {:noop, %{}}
            {:error, _} -> {:error, %{}}
          end

        stop(
          timers,
          :compaction,
          [:pie, :compaction],
          measurements,
          Map.put(meta, :result, outcome)
        )

      _other ->
        timers
    end
  end

  defp tool_meta(meta, call), do: Map.merge(meta, %{tool_name: call.name, tool_call_id: call.id})

  defp start(timers, key, prefix, meta) do
    now = System.monotonic_time()

    :telemetry.execute(
      prefix ++ [:start],
      %{system_time: System.system_time(), monotonic_time: now},
      meta
    )

    Map.put(timers, key, now)
  end

  defp stop(timers, key, prefix, measurements, meta, kind \\ :stop) do
    {started, timers} = Map.pop(timers, key)
    now = System.monotonic_time()
    duration = if started, do: now - started, else: 0

    :telemetry.execute(
      prefix ++ [kind],
      Map.merge(measurements, %{duration: duration, monotonic_time: now}),
      meta
    )

    # A crash ends every open span of the run.
    if kind == :exception, do: Map.take(timers, [:compaction]), else: timers
  end

  @doc "Logs every span's `stop` at `level`. Handy with `PIE_DEBUG=1`."
  def attach_default_logger(level \\ :debug) do
    stops = Enum.filter(@events, &(List.last(&1) in [:stop, :exception]))
    :telemetry.attach_many("pie-default-logger", stops, &__MODULE__.log_event/4, level)
  end

  @doc false
  def log_event([:pie, span, kind], measurements, meta, level) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    extra =
      meta |> Map.drop([:agent_id]) |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    Logger.log(level, "[pie #{meta.agent_id}] #{span} #{kind} in #{ms}ms #{extra}")
  end
end
