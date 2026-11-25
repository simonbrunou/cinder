defmodule Cinder.Indexers.Definitions.Set.Versions do
  @moduledoc """
  The root `VERSIONS` file of an upstream set: `MIN_VERSION` and `MAX_VERSION` as integers, and
  every `KEY=VALUE` line as text, those two included.
  """

  @enforce_keys [:min, :max, :values]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          min: non_neg_integer(),
          max: non_neg_integer(),
          values: %{String.t() => String.t()}
        }
end
