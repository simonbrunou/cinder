defmodule Cinder.Repo.Migrations.AddReleaseBlocklist do
  use Ecto.Migration

  def change do
    for tbl <- [:movies, :grabs] do
      alter table(tbl) do
        add :release_title, :string
      end
    end

    create table(:blocked_releases) do
      add :release_title, :string, null: false
      add :reason, :string
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :series_id, references(:series, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:blocked_releases, [:movie_id])
    create index(:blocked_releases, [:series_id])
  end
end
