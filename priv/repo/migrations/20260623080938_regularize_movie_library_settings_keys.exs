defmodule Cinder.Repo.Migrations.RegularizeMovieLibrarySettingsKeys do
  use Ecto.Migration

  # The library config keys were regularized per kind (movies/tv/…): the movie keys gained the
  # `movies_` prefix that TV keys already had. Rename any existing stored rows so a dogfood DB
  # keeps its movie library path + Plex section. TV rows (`tv_library_path`, `tv_min_size`, …)
  # are already prefixed and untouched. NOTE: this renames DB rows only — operators relying on
  # the env bootstrap must also rename LIBRARY_PATH → MOVIES_LIBRARY_PATH and
  # PLEX_SECTION → MOVIES_PLEX_SECTION in their compose/.env (see CHANGELOG).
  @renames [
    {"library_path", "movies_library_path"},
    {"plex_section", "movies_plex_section"}
  ]

  def up do
    for {old, new} <- @renames do
      execute("UPDATE settings SET key = '#{new}' WHERE key = '#{old}'")
    end
  end

  def down do
    for {old, new} <- @renames do
      execute("UPDATE settings SET key = '#{old}' WHERE key = '#{new}'")
    end
  end
end
