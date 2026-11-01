defmodule Cinder.Repo.Migrations.CreateSubtitleTrackRejections do
  use Ecto.Migration

  # #861: extracting a subtitle track reads the whole video file, and a sweep repeated the
  # extractions whose result could not change on every pass. A track whose content a check
  # rejected is kept per file (moviehash) and track, and so is a track probe whose output did not
  # parse, so the next sweep reads neither again.
  def change do
    create table(:subtitle_track_rejections) do
      add :moviehash, :string, null: false
      add :track_index, :integer, null: false
      add :check, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitle_track_rejections, [:moviehash, :track_index, :check])

    alter table(:subtitle_track_probes) do
      add :probe_error, :string
    end
  end
end
