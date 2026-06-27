defmodule Cinder.Repo.Migrations.AddImportedSource do
  use Ecto.Migration

  def change do
    for tbl <- [:movies, :episodes] do
      alter table(tbl) do
        add :imported_source, :string
      end
    end
  end
end
