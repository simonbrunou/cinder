defmodule Cinder.Repo.Migrations.CreateIndexerDefinitionPins do
  use Ecto.Migration

  # Each Cardigann configured indexer's running copy and held copy (#1668). Only
  # `Cinder.Indexers.Definitions` writes this table.
  def change do
    create table(:indexer_definition_pins, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      # A copy a pin names stays until no pin and no mirror entry use it.
      add :running_copy_id, references(:indexer_definition_copies), null: false
      add :held_copy_id, references(:indexer_definition_copies)
      # The hold's reason as an Erlang term; NULL with no hold. A hold that needs a newer Cinder
      # has a reason and no held copy.
      add :hold, :binary
    end

    create index(:indexer_definition_pins, [:running_copy_id])
    create index(:indexer_definition_pins, [:held_copy_id])
  end
end
