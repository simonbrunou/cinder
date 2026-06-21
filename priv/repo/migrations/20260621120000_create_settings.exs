defmodule Cinder.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      # Plaintext for non-secrets (inspectable via sqlite3); base64-encoded Cloak
      # ciphertext for is_secret rows.
      add :value, :string
      add :is_secret, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])
  end
end
