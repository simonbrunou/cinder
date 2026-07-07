defmodule Cinder.Repo.Migrations.AddMediaInfoToMoviesAndEpisodes do
  use Ecto.Migration

  def change do
    for table <- [:movies, :episodes] do
      alter table(table) do
        add :imported_audio_languages, {:array, :string}
        add :imported_embedded_subtitles, {:array, :string}
        add :imported_sidecar_subtitles, {:array, :string}
      end
    end
  end
end
