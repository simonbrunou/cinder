defmodule Cinder.Repo.Migrations.AddBookTargetPreferredLanguage do
  use Ecto.Migration

  def change do
    # The admin's language pick for a book target, set from `/books/:id` (not the movies/series
    # preference vocabulary of "original"/"french"/"dual"/"any" — a book edition has no audio
    # tracks to pick between). A raw code (ISO 639-1/639-2, or a release tag name) that
    # `Cinder.Acquisition.BookScorer.tag_for/1` already knows how to resolve, so no enum/CHECK
    # constraint here: a closed vocabulary would have to duplicate that resolver's own alias
    # table rather than trust it.
    #
    # Nullable, no default: NULL is already `BookScorer.check_language/2`'s
    # `check_language(_release, nil), do: :ok` — "no preference, accept everything" — so every
    # existing row (and every future target an admin never sets a language on) keeps today's
    # behavior exactly, with nothing to backfill.
    alter table(:book_targets) do
      add :preferred_language, :string
    end
  end
end
