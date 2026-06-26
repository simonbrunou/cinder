defmodule Cinder.Repo.Migrations.AddImportedQuality do
  use Ecto.Migration

  def change do
    for tbl <- [:movies, :episodes] do
      alter table(tbl) do
        add :imported_resolution, :string
        add :imported_size, :integer
        add :imported_language, :string
      end
    end
  end
end
