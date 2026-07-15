defmodule Cinder.Repo.Migrations.AddContentPathToMovies do
  use Ecto.Migration

  # PR #119 follow-up: movies overloaded file_path as both "download source" (pre-import) and
  # "library file" (post-import), unlike grabs which already have a dedicated content_path. This
  # gives movies the same first-class field. Additive + nullable, no backfill: a movie already
  # :downloaded when this ships keeps its pre-import path in file_path (content_path nil) until it
  # imports — Cinder.Catalog.Movie.download_source/1 is the read-side fallback for that window.
  def change do
    alter table(:movies) do
      add :content_path, :string
    end
  end
end
