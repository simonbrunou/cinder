defmodule Cinder.Repo.Migrations.MergeAnimeAudioModeIntoPreferredLanguage do
  use Ecto.Migration

  # Merges the per-title `anime_audio_mode` override and the global `/settings` →
  # "Anime releases" → Audio mode row into the single per-title `preferred_language` Audio
  # pick: for every no-override anime title, materializes exactly the previously effective
  # mode — per-title override wins, else the global row, else Original (the shipped bootstrap
  # default) — onto `preferred_language`. Runs the data pass before dropping the columns/row
  # it reads.
  #
  # Carve-out (import-time backstop): `preferred_language` already had a second, profile-ungated
  # duty pre-merge — `Cinder.Library`'s import-time audio check (`Language.target/2`) reads it for
  # every movie/series, anime or not. For an anime title whose old pick differed from the mode
  # materialized here, that import-time check's meaning changes too — a single merged value can't
  # express both the old acquisition-policy axis and the old import-check axis at once, and this
  # migration lets the acquisition-policy axis (the mode materialized below) win.
  #
  # Non-anime rows: any `anime_audio_mode` value on a title whose `media_profile` isn't 'anime'
  # (switched away from Anime with a stored override) is intentionally dropped, not materialized —
  # writing it into `preferred_language` would rewrite that title's live standard-path language
  # filter, which the override was never meant to drive.
  def up do
    global = global_audio_mode()

    for table <- ["movies", "series"] do
      execute("""
      UPDATE #{table}
      SET preferred_language = CASE anime_audio_mode
        WHEN 'original' THEN 'original'
        WHEN 'dub' THEN 'french'
        WHEN 'dual' THEN 'dual'
        WHEN 'any' THEN 'any'
        ELSE preferred_language
      END
      WHERE media_profile = 'anime' AND anime_audio_mode IS NOT NULL
      """)

      execute("""
      UPDATE #{table}
      SET preferred_language = '#{global}'
      WHERE media_profile = 'anime' AND anime_audio_mode IS NULL
      """)
    end

    execute("DELETE FROM settings WHERE key = 'anime_audio_mode'")

    alter table(:movies) do
      remove :anime_audio_mode
    end

    alter table(:series) do
      remove :anime_audio_mode
    end
  end

  # No data restore — the merged `preferred_language` value can't be split back into a global
  # setting + a per-title override.
  def down do
    alter table(:movies) do
      add :anime_audio_mode, :string
    end

    alter table(:series) do
      add :anime_audio_mode, :string
    end
  end

  # The previously effective global mode, materialized for every no-override anime title: an
  # explicit 'original' row and an absent row are the same shipped default, so both resolve to
  # "original" here — this never returns nil, so the caller's second UPDATE runs unconditionally.
  defp global_audio_mode do
    case repo().query!("SELECT value FROM settings WHERE key = 'anime_audio_mode'").rows do
      [["dub"]] -> "french"
      [["dual"]] -> "dual"
      [["any"]] -> "any"
      _absent_or_original -> "original"
    end
  end
end
