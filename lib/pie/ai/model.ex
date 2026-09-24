defmodule Pie.AI.Model do
  @moduledoc """
  A model is plain data: the provider that speaks its wire protocol, its id,
  and its limits.

  There is deliberately no built-in model catalog. Callers build models from
  configuration (`--model`, `PIE_MODEL`), so the library never goes stale when
  a vendor ships a new model. `provider` is either a registered name
  (`:anthropic`, `:faux`) or any module implementing `Pie.AI.Provider`.
  """

  @enforce_keys [:provider, :id]
  defstruct [
    :provider,
    :id,
    base_url: nil,
    context_window: 200_000,
    max_tokens: 16_384,
    options: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom() | module(),
          id: String.t(),
          base_url: String.t() | nil,
          context_window: pos_integer(),
          max_tokens: pos_integer(),
          options: map()
        }

  @spec new(atom() | module(), String.t(), keyword()) :: t()
  def new(provider, id, opts \\ []) do
    struct!(__MODULE__, [provider: provider, id: id] ++ opts)
  end
end
