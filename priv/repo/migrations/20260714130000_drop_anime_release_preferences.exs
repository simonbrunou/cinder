defmodule Cinder.Repo.Migrations.DropAnimeReleasePreferences do
  use Ecto.Migration

  # Per-title Anime release preferences (audio/subtitle/group/fallback-delay overrides on a
  # single movie or series) are removed: global-only until dogfood proves per-title need. The
  # global tier (`Cinder.Settings` / `/settings`) is unaffected.
  def change do
    alter table(:movies) do
      remove :audio_mode, :string
      remove :subtitle_languages, {:array, :string}
      remove :embedded_subtitle_mode, :string
      remove :preferred_release_groups, {:array, :string}
      remove :blocked_release_groups, {:array, :string}
      remove :group_fallback_delay, :integer
    end

    alter table(:series) do
      remove :audio_mode, :string
      remove :subtitle_languages, {:array, :string}
      remove :embedded_subtitle_mode, :string
      remove :preferred_release_groups, {:array, :string}
      remove :blocked_release_groups, {:array, :string}
      remove :group_fallback_delay, :integer
    end
  end
end
