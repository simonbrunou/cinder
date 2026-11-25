defmodule Cinder.Indexers.Definitions.Entry do
  @moduledoc """
  One file name of the mirror set. Only `Cinder.Indexers.Definitions` writes these rows.

  - `blob_sha` and `folder` name the mirror's copy: the one in the highest folder the engine
    reads. Both are nil for a name that only folders above the engine hold.
  - `newer_folder`: the highest folder above the engine that holds a copy other than the
    mirror's, recorded without its bytes.
  - `needs_version`: for a name with no mirror copy, the lowest folder above the engine that
    holds it.
  - `replaces`: the names the mirror copy's definition lists under `replaces`, taken from its
    load result under the current fingerprint; `[]` while the copy has none, until
    `Cinder.Indexers.Definitions.store_results/1` stores one.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "indexer_definition_entries" do
    field :name, :string
    field :blob_sha, :string
    field :folder, :integer
    field :newer_folder, :integer
    field :needs_version, :integer
    field :replaces, {:array, :string}, default: []
  end
end
