defmodule Cinder.Repo.Migrations.CreateConfiguredIndexers do
  use Ecto.Migration

  # What the admin configures for searching one indexer (#1649). Only `Cinder.Indexers` writes
  # this table.
  def change do
    create table(:configured_indexers, primary_key: false) do
      # :bigserial makes ecto_sqlite3 write AUTOINCREMENT, so a deleted id is never reused and
      # never names a new indexer in a row that still points at the old one.
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      # newznab, torznab or cardigann; fixed at create.
      add :type, :string, null: false
      # The Cardigann definition file name; NULL for Newznab and Torznab.
      add :definition, :string
      add :base_url, :string, null: false
      add :api_path, :string
      add :enabled, :boolean, null: false, default: true
      add :flaresolverr, :boolean, null: false, default: false
      # Plain values only, such as Newznab additional parameters.
      add :settings, :map, null: false, default: %{}
      # One Base64 Vault ciphertext per row, NULL when the row has no secret.
      add :secrets_ciphertext, :text

      # SQLite's integer affinity still stores 1.5 as a real, so the check names the type too.
      add :priority, :integer,
        null: false,
        default: 25,
        check: %{
          name: "configured_indexers_priority_range",
          expr: "typeof(priority) = 'integer' AND priority BETWEEN 1 AND 50"
        }

      add :prowlarr_indexer_id, :integer
      add :lock_version, :integer, null: false, default: 1
      add :credentials_version, :integer, null: false, default: 1
      add :config_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:configured_indexers, [:name])
    create unique_index(:configured_indexers, [:prowlarr_indexer_id])
  end
end
