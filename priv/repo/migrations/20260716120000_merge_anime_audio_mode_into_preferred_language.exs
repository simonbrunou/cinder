defmodule Cinder.Repo.Migrations.MergeAnimeAudioModeIntoPreferredLanguage do
  use Ecto.Migration

  # Merges the per-title `anime_audio_mode` override and the global `/settings` →
  # "Anime releases" → Audio mode row into the single per-title `preferred_language` Audio
  # pick: per-title override wins, else the global row, else the title's `preferred_language`
  # is left unchanged. Runs the data pass before dropping the columns/row it reads.
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

      if global do
        execute("""
        UPDATE #{table}
        SET preferred_language = '#{global}'
        WHERE media_profile = 'anime' AND anime_audio_mode IS NULL
        """)
      end
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

  # 'original' (the shipped default) and an absent row both need no rewrite — only a
  # non-default, non-secret global row maps a title's audio.
  defp global_audio_mode do
    case repo().query!("SELECT value FROM settings WHERE key = 'anime_audio_mode'").rows do
      [["dub"]] -> "french"
      [["dual"]] -> "dual"
      [["any"]] -> "any"
      _absent_or_original -> nil
    end
  end
end
