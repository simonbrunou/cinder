defmodule Cinder.Library.SeasonAdoption do
  @moduledoc """
  Adopts the files a TV library root already holds for a requested season, before the TV sweep
  first searches it (#720), so a season partly on the media server is not downloaded again.

  `Cinder.Download.TvPoller` calls `check/2` for a series whose due episodes include a season a
  request approval armed (`seasons.library_check_armed_at`). Unlike `/library/adopt`
  (`Cinder.Library.Adoption`), nobody confirms these matches, so only unambiguous ones adopt:

    * The folder is a top-level folder of a TV root that carries the show's `{tmdb-N}` tag, or
      its `{tvdb-N}` tag when the series has a TVDB id, or that carries neither tag and whose
      title and year find exactly one TMDB show with that title and year, this series
      (`Adoption.exact_match/3`). A folder tagged with another show's id never matches.
    * A file adopts when its name reads as `SxxEyy` of a checked season, every episode it names is
      an episode of that season with no file and no grab, it is not sample-named
      (`MovieSources.sample_name?/2`), and no other file in the series' folders claims one of its
      episodes. Any other file waits for `/library/adopt`, and its episode stays wanted.
    * A series whose effective profile is Anime, or that has a scene numbering group, adopts
      nothing here: its file numbers need not be TMDB's.

  The writes go through `Cinder.Catalog.Adoption` (`Catalog.adopt_episode_files/1`), which
  leaves the series' profile alone.

  Every directory read runs in `Cinder.Library.BoundedWalk.run/3` under its TV root's key, 30 s
  each: one listing of the root's top level, then one walk of the matched folders that also
  checks each file through `PathPolicy.source_file/4`. `check/2` returns `{:hold, reason}`
  instead of raising when a read misses its deadline or fails, TMDB does not answer, or the write
  meets a row another writer changed; the caller then leaves the season unsearched and checks
  again on a later tick.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Series}
  alias Cinder.Library
  alias Cinder.Library.{Adoption, BoundedWalk, MovieSources}
  alias Cinder.Settings

  @walk_timeout_ms 30_000

  @type result :: {:done, [integer()]} | {:hold, term()}

  @doc """
  Adopts the unambiguous files of `season_numbers` of `series` found under the TV roots.

  Returns `{:done, episode_ids}` with the ids of the episodes it adopted, which can be `[]`: no
  TV root, no folder of the show, nothing that matches. Returns `{:hold, reason}` when the check
  could not finish this time.
  """
  @spec check(Series.t(), [integer()]) :: result()
  def check(%Series{} = series, season_numbers) when is_list(season_numbers) do
    if numbering_trusted?(series) do
      series
      |> roots_with_folders()
      |> adopt_from_folders(series, season_numbers)
    else
      {:done, []}
    end
  end

  defp numbering_trusted?(%Series{scene_numbering_group_id: group}) when is_binary(group),
    do: false

  defp numbering_trusted?(series), do: Catalog.media_profile_summary(series).effective != :anime

  defp tv_roots do
    Settings.library_destinations()
    |> Enum.filter(&(&1.kind == :tv))
    |> Enum.map(&Path.expand(&1.path))
    |> Enum.uniq()
  end

  # `{:ok, [{root, [folder]}]}`, the show's folders under each TV root, or `{:hold, reason}`.
  defp roots_with_folders(series) do
    Enum.reduce_while(tv_roots(), {:ok, []}, fn root, {:ok, acc} ->
      with {:ok, names} <- list_root(root),
           {:ok, folders} <- series_folders(names, series) do
        {:cont, {:ok, [{root, Enum.map(folders, &Path.join(root, &1))} | acc]}}
      else
        {:hold, _reason} = hold -> {:halt, hold}
      end
    end)
  end

  defp list_root(root) do
    case BoundedWalk.run(root, fn -> filesystem().ls(root) end, timeout_ms: walk_timeout_ms()) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:hold, {:list_failed, root, reason}}
    end
  end

  defp series_folders(names, series) do
    titles = series_titles(series)

    {tagged, titled} =
      names
      |> Enum.map(&{&1, Adoption.parse_directory(&1)})
      |> Enum.reduce({[], []}, fn {name, parsed}, {tagged, titled} ->
        case folder_kind(parsed, series, titles) do
          :tagged -> {[name | tagged], titled}
          :titled -> {tagged, [{name, parsed} | titled]}
          :other -> {tagged, titled}
        end
      end)

    with {:ok, confirmed} <- confirm_titled(Enum.reverse(titled), series) do
      {:ok, Enum.reverse(tagged) ++ confirmed}
    end
  end

  defp folder_kind(%{provider_tag: {:tmdb_id, id}}, %Series{tmdb_id: id}, _titles), do: :tagged

  defp folder_kind(%{provider_tag: {:tvdb_id, id}}, %Series{tvdb_id: id}, _titles)
       when is_integer(id),
       do: :tagged

  defp folder_kind(%{provider_tag: {source, _id}}, _series, _titles)
       when source in [:tmdb_id, :tvdb_id],
       do: :other

  defp folder_kind(%{title: title, year: year}, %Series{year: year}, titles)
       when is_integer(year) do
    if Adoption.normalize_title(title) in titles, do: :titled, else: :other
  end

  defp folder_kind(_parsed, _series, _titles), do: :other

  defp series_titles(%Series{title: title, localizations: localizations}) do
    localized =
      for {_locale, %{"title" => value}} <- localizations || %{},
          is_binary(value) and value != "",
          do: value

    [title | localized]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Adoption.normalize_title/1)
    |> Enum.uniq()
  end

  # A folder named by title and year only counts when TMDB finds exactly one show with that title
  # and year, and that show is this series: the rule `/library/adopt` auto-matches by.
  defp confirm_titled(titled, series) do
    titled
    |> Enum.group_by(fn {_name, parsed} -> parsed.title end)
    |> Enum.reduce_while({:ok, []}, fn {title, folders}, {:ok, acc} ->
      case Catalog.search_tv(title) do
        {:ok, results} ->
          {:cont, {:ok, acc ++ confirmed_names(results, folders, series)}}

        {:error, reason} ->
          {:halt, {:hold, {:tmdb_search_failed, reason}}}
      end
    end)
  end

  defp confirmed_names(results, folders, %Series{tmdb_id: tmdb_id}) do
    for {name, parsed} <- folders,
        match?(
          {:ok, %{tmdb_id: ^tmdb_id}},
          Adoption.exact_match(results, parsed.title, parsed.year)
        ),
        do: name
  end

  defp adopt_from_folders({:hold, _reason} = hold, _series, _season_numbers), do: hold

  defp adopt_from_folders({:ok, roots}, series, season_numbers) do
    with {:ok, files} <- walk_folders(roots) do
      files
      |> plan(Catalog.get_series_with_tree(series.id), season_numbers)
      |> write()
    end
  end

  defp walk_folders(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn
      {_root, []}, acc ->
        {:cont, acc}

      {root, folders}, {:ok, acc} ->
        case walk_root(root, folders) do
          {:ok, files} -> {:cont, {:ok, acc ++ files}}
          {:hold, _reason} = hold -> {:halt, hold}
        end
    end)
  end

  defp walk_root(root, folders) do
    case BoundedWalk.run(root, fn -> read_folders(root, folders) end,
           timeout_ms: walk_timeout_ms()
         ) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:hold, {:walk_failed, root, reason}}
    end
  end

  # Runs inside the root's bounded walk: the folder walks and each file's `PathPolicy.source_file/4`
  # check read the same mount.
  defp read_folders(root, folders) do
    Enum.reduce_while(folders, {:ok, []}, fn folder, {:ok, acc} ->
      case filesystem().find_files(folder) do
        {:ok, files} -> {:cont, {:ok, acc ++ safe_videos(files, root)}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, :enotdir} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_videos(files, root) do
    for {path, size} <- files,
        Library.video_file?(path),
        not MovieSources.sample_name?(path, size),
        {:ok, expanded} <- [source_file(path, root)],
        do: expanded
  end

  defp source_file(path, root) do
    Library.path_policy().source_file(path, [root], Library.video_extensions(),
      filesystem: filesystem()
    )
  end

  defp plan(files, %Series{seasons: seasons}, season_numbers) do
    managed = Adoption.managed_paths()

    episodes =
      for season <- seasons,
          season.season_number in season_numbers,
          episode <- season.episodes,
          into: %{},
          do: {{season.season_number, episode.episode_number}, episode}

    claims =
      files
      |> Enum.reject(&MapSet.member?(managed, &1))
      |> Enum.map(&claim(&1, episodes))
      |> Enum.reject(&is_nil/1)

    contested = contested_keys(claims)

    for {path, keys} <- claims,
        not Enum.any?(keys, &MapSet.member?(contested, &1)),
        Enum.all?(keys, &free?(Map.fetch!(episodes, &1))),
        {season_number, episode_number} = key <- keys,
        do: action(Map.fetch!(episodes, key), season_number, episode_number, path)
  end

  defp plan(_files, _missing_series, _season_numbers), do: []

  # The episode keys a file names, when it names episodes of a checked season that all exist.
  defp claim(path, episodes) do
    case Adoption.parse_episode_file(path) do
      %{status: :pending, season_number: season, episode_numbers: numbers} ->
        keys = Enum.map(numbers, &{season, &1})
        if Enum.all?(keys, &Map.has_key?(episodes, &1)), do: {path, keys}

      _unparsed ->
        nil
    end
  end

  defp contested_keys(claims) do
    claims
    |> Enum.flat_map(fn {_path, keys} -> Enum.uniq(keys) end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> MapSet.new(fn {key, _count} -> key end)
  end

  defp free?(%Episode{file_path: nil, grab_id: nil}), do: true
  defp free?(_episode), do: false

  defp action(%Episode{} = episode, season_number, episode_number, path) do
    %{
      episode: episode,
      episode_code: Episode.code(season_number, episode_number),
      path: path,
      type: :primary
    }
  end

  defp write([]), do: {:done, []}

  defp write(actions) do
    case Catalog.adopt_episode_files(actions) do
      {:ok, applied} -> {:done, applied |> Enum.map(& &1.episode.id) |> Enum.uniq()}
      {:error, failures} -> {:hold, {:adoption_refused, failures}}
    end
  end

  # A test seam, like `Adoption`'s `:adoption_scan_timeout_ms`: production never sets it.
  defp walk_timeout_ms,
    do: Application.get_env(:cinder, :season_adoption_timeout_ms, @walk_timeout_ms)

  defp filesystem, do: Application.fetch_env!(:cinder, :filesystem)
end
