defmodule Cinder.TestPartitions.Partition do
  @moduledoc """
  One partition of a bare `mix test` (`Cinder.TestPartitions`): its number, its copy of the build
  folder, its log file, and once it ended, its exit status.
  """

  @enforce_keys [:n, :build, :log]
  defstruct [:n, :build, :log, :status]

  @type t :: %__MODULE__{
          n: pos_integer(),
          build: Path.t(),
          log: Path.t(),
          status: non_neg_integer() | nil
        }
end
