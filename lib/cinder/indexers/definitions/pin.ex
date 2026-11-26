defmodule Cinder.Indexers.Definitions.Pin do
  @moduledoc """
  One Cardigann configured indexer's definition copies (#1668): the copy it runs, the copy held
  back from it (nil with none) and the hold's reason (nil with none). A hold that needs a newer
  Cinder has a reason and no held copy. Only `Cinder.Indexers.Definitions` writes these rows;
  deleting the configured indexer deletes its row.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "indexer_definition_pins" do
    field :running_copy_id, :id
    field :held_copy_id, :id
    field :hold, :binary
  end
end
