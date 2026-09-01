defmodule Cinder.Repo.Migrations.AddBookGrabReplaceFlag do
  use Ecto.Migration

  def change do
    # Marks a grab as a confirmed "Find a better match" replace rather than a fresh acquisition —
    # `Cinder.Books.Files.record_import/3` reads this (via `BookPoller`) to decide whether the
    # target's existing file should be superseded on import. Defaulted `false` so every existing
    # and future ordinary grab is unaffected.
    alter table(:book_grabs) do
      add :replace, :boolean, null: false, default: false
    end
  end
end
