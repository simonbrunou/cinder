defmodule Cinder.Repo.Migrations.AddAnimeHoldAndAudioOverride do
  use Ecto.Migration

  # Issue #107: `anime_hold_reason` makes the search-time "invalid Anime preferences" hold
  # DB-visible (previously only a repeating log line); `anime_audio_mode` is the narrow
  # single-axis per-title override of the global Anime audio mode (nil = use global).
  def change do
    alter table(:movies) do
      add :anime_hold_reason, :string
      add :anime_audio_mode, :string
    end

    alter table(:series) do
      add :anime_hold_reason, :string
      add :anime_audio_mode, :string
    end
  end
end
