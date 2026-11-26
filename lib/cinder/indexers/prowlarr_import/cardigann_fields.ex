defmodule Cinder.Indexers.ProwlarrImport.CardigannFields do
  @moduledoc """
  What `Cinder.Indexers.ProwlarrImport.Answer` keeps of a Prowlarr Cardigann indexer (#1675): its
  definition `file` as Prowlarr stores it, every field's raw `values` by name, and each select's
  `select_options` as `{position, label}` pairs. `values` holds the passwords, cookies and other
  secrets Prowlarr answers in clear, so `inspect/1`, and with it a crash report that prints the
  struct, leaves it out.
  """

  @derive {Inspect, except: [:values]}
  @enforce_keys [:file, :values, :select_options]
  defstruct [:file, :values, :select_options]

  @type t :: %__MODULE__{
          file: String.t(),
          values: %{optional(String.t()) => term()},
          select_options: %{optional(String.t()) => [{integer(), String.t()}]}
        }
end
