defmodule Cinder.Indexers.Definitions.LoadResult do
  @moduledoc """
  The load check's answer for one blob hash under one engine fingerprint
  (`Cinder.Indexers.Definitions.Loader.fingerprint/0`). Only `Cinder.Indexers.Definitions`
  writes these rows.

  `outcome` is `:loads`, `:not_supported` or `:fails`. `detail` holds the not-supported codes in
  the loader's order, or the failure reason, as an Erlang term; nil for `:loads`. A copy that
  parses also stores its display `id`, privacy (its `type`), language, description and the names
  it lists under `replaces`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "indexer_definition_load_results" do
    field :blob_sha, :string
    field :schema_version, :integer
    field :revision, :integer
    field :outcome, Ecto.Enum, values: [:loads, :not_supported, :fails]
    field :detail, :binary
    field :definition_id, :string
    field :privacy, :string
    field :language, :string
    field :description, :string
    field :replaces, {:array, :string}, default: []
  end
end
