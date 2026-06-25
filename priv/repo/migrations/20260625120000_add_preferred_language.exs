defmodule Cinder.Repo.Migrations.AddPreferredLanguage do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :original_language, :string
      add :preferred_language, :string, default: "original", null: false
    end

    alter table(:series) do
      add :original_language, :string
      add :preferred_language, :string, default: "original", null: false
    end

    alter table(:requests) do
      add :original_language, :string
      add :preferred_language, :string
    end
  end
end
