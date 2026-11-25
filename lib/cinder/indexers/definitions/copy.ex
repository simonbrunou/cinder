defmodule Cinder.Indexers.Definitions.Copy do
  @moduledoc """
  One stored copy of an upstream definition file: its git blob hash, its folder number (11 for
  `v11`), its file name and its bytes. Only `Cinder.Indexers.Definitions` writes these rows.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "indexer_definition_copies" do
    field :blob_sha, :string
    field :folder, :integer
    field :name, :string
    field :bytes, :binary
  end
end
