defmodule Cinder.Indexers.Definitions.Set.DefinitionFile do
  @moduledoc """
  One `definitions/<folder>/<name>` file of an upstream set: its folder (`"v11"`), its file name
  (`"nyaasi.yml"`), the git blob hash of its bytes in lowercase hex, and the bytes. #1667 keys
  stored copies on the folder and the blob hash.
  """

  @enforce_keys [:folder, :name, :blob_sha, :bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          folder: String.t(),
          name: String.t(),
          blob_sha: String.t(),
          bytes: binary()
        }
end
