defmodule Cinder.Library.Naming do
  @moduledoc """
  Where an imported file lands: the Plex-scheme folder and file names Cinder renames to.

  Carved out of `Cinder.Library` as plain code motion — every rule below is byte-for-byte what it
  was before the split. Pure functions: no filesystem, no config, no Repo, so the containment
  checks stay where they were (`Cinder.Library.PathPolicy` still vets every path these produce).
  """
  alias Cinder.Catalog.{Episode, Movie}

  @illegal ~r/[\/\\:*?"<>|]/

  @doc "`root/Title (Year) {tmdb-id}/Title (Year) {tmdb-id}.ext` for a movie."
  def movie_dest(%Movie{title: title, year: year, tmdb_id: tmdb_id}, source, root) do
    name = library_name(sanitize(title), year, tmdb_id)
    Path.join([root, name, name <> Path.extname(source)])
  end

  @doc """
  `root/Show (Year) {tmdb-id}/Season NN/Show (Year) {tmdb-id} - SxxEyy.ext` for the episodes one
  source file covers — a double-episode file gets one destination that both episodes reference.
  """
  def episode_dest([%Episode{season: season} | _] = episodes, source, root) do
    show = library_name(sanitize(season.series.title), season.series.year, season.series.tmdb_id)
    code = episode_code(episodes)

    Path.join([
      root,
      show,
      "Season #{Episode.pad(season.season_number)}",
      "#{show} - #{code}#{Path.extname(source)}"
    ])
  end

  @doc "The canonical destination for a residual video an operator folded onto an episode."
  def episode_part_dest(episode, source, root, grab_file_id) do
    base = episode_dest([episode], source, root)
    extension = Path.extname(base)
    "#{Path.rootname(base, extension)}-part-#{grab_file_id}#{extension}"
  end

  defp episode_code([%Episode{season: season} | _] = episodes) do
    Episode.codes_label(season.season_number, Enum.map(episodes, & &1.episode_number))
  end

  # Plex's scheme is `Title (Year) {tmdb-<id>}`; with no year (a TMDB entry lacking a
  # release date) fall back to `Title {tmdb-<id>}`, and if the title sanitizes to
  # nothing (all-illegal characters) fall back to a bare tmdb id so the file lands in
  # its own folder rather than the library root.
  defp library_name("", _year, tmdb_id), do: "tmdb-#{tmdb_id}"
  defp library_name(title, nil, tmdb_id), do: "#{title} {tmdb-#{tmdb_id}}"
  defp library_name(title, year, tmdb_id), do: "#{title} (#{year}) {tmdb-#{tmdb_id}}"

  # Strip filesystem-illegal characters, then trim surrounding whitespace so a
  # title that is blank after sanitizing collapses to "" and hits the tmdb-id
  # fallback rather than producing a whitespace-named folder.
  defp sanitize(title) do
    title
    |> String.replace(@illegal, "")
    |> String.trim()
    |> reject_dot_only()
  end

  # A name that is only dots (".", "..", …) would become a path segment that escapes the library
  # root (`Path.join([root, "..", …])`). Collapse it to "" so library_name falls back to the
  # tmdb-id folder, same as an all-illegal title.
  defp reject_dot_only(name), do: if(name =~ ~r/\A\.+\z/, do: "", else: name)
end
