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

    # The whole migration runs in one transaction, and releases migrate at boot before the
    # pollers start, so nothing races this pass — only a manual `mix ecto.migrate` against a
    # RUNNING instance could hit SQLITE_BUSY, and busy_timeout (5000 ms) covers that.
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

  # Irreversible by design — re-adding NULL `anime_audio_mode` columns here would silently
  # invite a down→up re-run to stamp every anime title back to 'original'.
  def down do
    raise Ecto.MigrationError,
      message: """
      This migration cannot be rolled back: `up` merged the per-title `anime_audio_mode` override
      and the global anime Audio-mode setting into `preferred_language`, then deleted both the
      `anime_audio_mode` columns and the `anime_audio_mode` settings row. That source data no
      longer exists, so the merge can't be undone — restore from a pre-migration backup instead.
      """
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
