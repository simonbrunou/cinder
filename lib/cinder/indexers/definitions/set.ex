defmodule Cinder.Indexers.Definitions.Set do
  @moduledoc """
  The upstream definitions `Cinder.Indexers.Definitions.Archive.read/2` reads from one
  Prowlarr/Indexers commit: the commit, its `VERSIONS` values and every kept definition file, in
  the zip's directory order.
  """

  alias Cinder.Indexers.Definitions.Set.{DefinitionFile, Versions}

  @enforce_keys [:commit, :versions, :files]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          commit: String.t(),
          versions: Versions.t(),
          files: [DefinitionFile.t()]
        }
end
