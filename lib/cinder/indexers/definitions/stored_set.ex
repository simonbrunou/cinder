defmodule Cinder.Indexers.Definitions.StoredSet do
  @moduledoc """
  The one row of the mirror set and its state. Only `Cinder.Indexers.Definitions` writes it.

  `commit`, `versions`, `count` and `loaded_at` describe the set the mirror holds: `count` is the
  number of names the guard counted in the answer it came from. `state` is the last apply's
  outcome; a refusal keeps the set's fields and records the refused answer in the `refused_*`
  and `shrink_percent` fields. `refused_versions` keeps a refused answer's `VERSIONS` values as
  text, since its `MIN_VERSION` can be past SQLite's integer. `accepted_commit` is the refused
  commit "Accept smaller set" took, until an apply succeeds or a refusal at another commit
  follows.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}
  schema "indexer_definition_set" do
    field :commit, :string
    field :versions, :map
    field :count, :integer
    field :loaded_at, :utc_datetime
    field :state, Ecto.Enum, values: [:loaded, :cinder_too_old, :shrank, :first_too_small]
    field :refused_commit, :string
    field :refused_count, :integer
    field :shrink_percent, :integer
    field :refused_versions, :map
    field :accepted_commit, :string
  end
end
