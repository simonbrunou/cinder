defmodule Cinder.Repo.Migrations.CreateSubtitleTrackProbes do
  use Ecto.Migration

  # Spec 069 (option C): before searching OpenSubtitles, Cinder looks for the video's own full
  # subtitle track. Listing a file's text tracks with their cue counts reads the whole file, so the
  # result is kept per video (moviehash): a file whose only track is image-based or a signs track
  # is not read again on every sweep.
  def change do
    create table(:subtitle_track_probes) do
      add :moviehash, :string, null: false
      add :tracks, {:array, :map}, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitle_track_probes, [:moviehash])
  end
end
