defmodule Cinder.RepoWatch.Thresholds do
  @moduledoc """
  The hold, queue and stall thresholds of `Cinder.RepoWatch`, in milliseconds. `read/0` takes
  each from `config :cinder, Cinder.RepoWatch` (`hold_ms`, `queue_ms`, `stall_ms`), else 1 s.
  """

  @default_ms 1_000

  @enforce_keys [:hold, :queue, :stall]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hold: non_neg_integer(),
          queue: non_neg_integer(),
          stall: non_neg_integer()
        }

  @doc "The thresholds app config sets, 1 s each by default."
  @spec read() :: t()
  def read do
    config = Application.get_env(:cinder, Cinder.RepoWatch, [])

    %__MODULE__{
      hold: Keyword.get(config, :hold_ms, @default_ms),
      queue: Keyword.get(config, :queue_ms, @default_ms),
      stall: Keyword.get(config, :stall_ms, @default_ms)
    }
  end
end
