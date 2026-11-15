defmodule Cinder.Repo.Migrations.AddEpisodeImportedDefaultAudioLanguage do
  use Ecto.Migration

  # The episode counterpart of `movies.imported_default_audio_language` (issue #786): the language
  # of the file's default-disposition audio track, so the series page can show the same
  # default-audio hint as the movie page. Nil means "not established", as for movies, and never
  # warns, so existing rows need no backfill.
  def change do
    alter table(:episodes) do
      add :imported_default_audio_language, :string
    end
  end
end
