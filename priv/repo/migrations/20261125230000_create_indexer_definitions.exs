defmodule Cinder.Repo.Migrations.CreateIndexerDefinitions do
  use Ecto.Migration

  # The mirror of the upstream indexer definitions (#1667). Only `Cinder.Indexers.Definitions`
  # writes these tables.
  def change do
    # One stored copy of a definition file: its git blob hash and folder number, its file name and
    # its bytes.
    create table(:indexer_definition_copies) do
      add :blob_sha, :string, null: false
      add :folder, :integer, null: false
      add :name, :string, null: false
      add :bytes, :binary, null: false
    end

    create unique_index(:indexer_definition_copies, [:blob_sha, :folder])

    # The load check's answer for one blob hash under one engine fingerprint, with the display
    # fields of a copy that parses (NULL for one that fails to load).
    create table(:indexer_definition_load_results) do
      add :blob_sha, :string, null: false
      add :schema_version, :integer, null: false
      add :revision, :integer, null: false

      add :outcome, :string,
        null: false,
        check: %{
          name: "indexer_definition_load_results_outcome",
          expr: "outcome IN ('loads', 'not_supported', 'fails')"
        }

      # The not-supported codes in the loader's order, or the failure reason, as an Erlang term.
      add :detail, :binary
      add :definition_id, :string
      add :privacy, :string
      add :language, :string
      add :description, :text
      add :replaces, {:array, :string}, null: false, default: []
    end

    create unique_index(:indexer_definition_load_results, [:blob_sha, :schema_version, :revision])

    # One entry per file name of the mirror set. `blob_sha` and `folder` name its copy; both are
    # NULL for a name that only folders above the engine hold.
    create table(:indexer_definition_entries) do
      add :name, :string, null: false
      add :blob_sha, :string
      add :folder, :integer
      # The highest folder above the engine that holds a different copy of the name.
      add :newer_folder, :integer
      # For a name only folders above the engine hold: the lowest of them.
      add :needs_version, :integer
      add :replaces, {:array, :string}, null: false, default: []
    end

    create unique_index(:indexer_definition_entries, [:name])

    # The one row of the mirror set and its state.
    create table(:indexer_definition_set, primary_key: false) do
      add :id, :integer,
        primary_key: true,
        check: %{name: "indexer_definition_set_singleton", expr: "id = 1"}

      add :commit, :string
      add :versions, :map
      add :count, :integer
      add :loaded_at, :utc_datetime

      add :state, :string,
        null: false,
        check: %{
          name: "indexer_definition_set_state",
          expr: "state IN ('loaded', 'cinder_too_old', 'shrank', 'first_too_small')"
        }

      add :refused_commit, :string
      add :refused_count, :integer
      add :shrink_percent, :integer
      # The refused answer's VERSIONS values, as text: a MIN_VERSION can pass SQLite's integer.
      add :refused_versions, :map
      add :accepted_commit, :string
    end
  end
end
