defmodule Pie.Tool do
  @moduledoc """
  A tool is data: a JSON Schema the model sees, plus an `execute` function.

  `execute.(args, ctx)` runs in its own process (see `Pie.Agent.Scheduler`)
  and returns one of:

      {:ok, text}
      {:ok, text, details}   # details: JSON-encodable, kept for UIs and logs
      {:error, text}

  Raising, crashing or timing out is fine: the scheduler turns it into an
  error result for the model. `ctx` holds `:tool_call_id` and `:update`, a
  function that streams partial output (a string) to observers.

  `parallel: true` marks a tool as safe to run concurrently with other
  parallel tools (read-only tools). Every other tool runs alone.
  `timeout` is in milliseconds or `:infinity`.
  """

  @enforce_keys [:name, :description, :parameters, :execute]
  defstruct [:name, :description, :parameters, :execute, parallel: false, timeout: 120_000]

  @type result :: {:ok, String.t()} | {:ok, String.t(), term()} | {:error, String.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          execute: (map(), map() -> result()),
          parallel: boolean(),
          timeout: timeout()
        }

  @doc """
  Checks arguments against the parts of JSON Schema that matter in practice:
  required properties and primitive types. Errors go back to the model, which
  corrects itself far more reliably than any coercion would.
  """
  @spec validate(map(), term()) :: :ok | {:error, String.t()}
  def validate(schema, args) when is_map(args) do
    required = Enum.map(get(schema, :required, []), &to_string/1)

    missing =
      for key <- required, not Map.has_key?(args, key), do: "missing required property \"#{key}\""

    wrong =
      Enum.flat_map(get(schema, :properties, %{}), fn {key, spec} ->
        value = Map.get(args, to_string(key))
        type = get(spec, :type, nil)
        if value == nil or type?(type, value), do: [], else: ["\"#{key}\" must be #{type}"]
      end)

    case missing ++ wrong do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "; ")}
    end
  end

  def validate(_schema, _args), do: {:error, "arguments must be a JSON object"}

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp type?("string", v), do: is_binary(v)
  defp type?("integer", v), do: is_integer(v)
  defp type?("number", v), do: is_number(v)
  defp type?("boolean", v), do: is_boolean(v)
  defp type?("array", v), do: is_list(v)
  defp type?("object", v), do: is_map(v)
  defp type?(_other, _v), do: true
end
