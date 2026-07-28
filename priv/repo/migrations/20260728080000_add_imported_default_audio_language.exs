defmodule Cinder.Repo.Migrations.AddImportedDefaultAudioLanguage do
  use Ecto.Migration

  # The language of the file's default-disposition audio track: what a player actually starts on,
  # which `imported_audio_languages` cannot express (issue #197). Nil means "not established" —
  # no stream flagged default, the flagged one carried no language tag, or the row predates this
  # column. Nil never warns; `mix cinder.media_info.backfill` fills it in for existing rows.
  #
  # Movies only on purpose: the mis-default hint renders on the movie page. Episodes go through the
  # same probe and simply drop the value, and can grow their own column if that hint ever lands.
  def change do
    alter table(:movies) do
      add :imported_default_audio_language, :string
    end
  end
end
