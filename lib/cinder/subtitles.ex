defmodule Cinder.Subtitles do
  @moduledoc """
  Best-effort subtitle coordinator for imported videos.

  It records Cinder-owned sidecars in a hidden manifest, so hash-matched provider results are
  stable while ID, embedded, translated, and release sidecars remain eligible for later upgrades.
  """

  require Logger

  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.{PathPolicy, Sidecars}
  alias Cinder.Settings
  alias Cinder.Subtitles.{Manifest, Moviehash, Srt}

  @doc "Subtitle-search criteria for a movie: imdb + tmdb id (the provider prefers imdb)."
  @spec movie_criteria(Movie.t()) :: map()
  def movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id}),
    do: %{imdb_id: imdb_id, tmdb_id: tmdb_id}

  @doc "Subtitle-search criteria for an episode: series tmdb id + season/episode numbers."
  @spec episode_criteria(Episode.t()) :: map()
  def episode_criteria(%Episode{
        episode_number: number,
        season: %{season_number: season, series: %Series{tmdb_id: tmdb_id}}
      }),
      do: %{tmdb_id: tmdb_id, season: season, episode: number}

  @doc "Configured subtitle languages (downcased). `[]` — feature off — when the setting is blank."
  @spec wanted_languages() :: [String.t()]
  def wanted_languages do
    provider_config()
    |> Keyword.get(:languages, "")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The ordinary media-server sidecar path: `video.lang.srt`."
  @spec sidecar_path(String.t(), String.t()) :: String.t()
  def sidecar_path(video_path, language) do
    dir = Path.dirname(video_path)
    base = Path.basename(video_path, Path.extname(video_path))
    Path.join(dir, "#{base}.#{language}.srt")
  end

  @doc "Compatibility wrapper for direct movie-context callers."
  @spec fetch_missing(map(), String.t()) :: :ok | :quota_exceeded
  def fetch_missing(criteria_base, video_path),
    do: fetch_missing(criteria_base, video_path, :movies)

  @doc "Fetches each configured language, refreshing only sidecars Cinder owns."
  @spec fetch_missing(map(), String.t(), :movies | :tv) :: :ok | :quota_exceeded
  def fetch_missing(criteria_base, video_path, kind) do
    case wanted_languages() do
      [] -> :ok
      languages -> fetch_languages(criteria_base, languages, video_path, kind)
    end
  end

  @doc "Compatibility wrapper for existing import callers; Task 4 supplies provenance arguments."
  @spec fetch_after_import((-> map()), String.t()) :: :ok
  def fetch_after_import(criteria_fun, video_path),
    do: fetch_after_import(criteria_fun, video_path, :movies, [])

  @doc "Runs subtitle work off the import path and marks current release sidecars as Cinder-managed."
  @spec fetch_after_import((-> map()), String.t(), :movies | :tv, [String.t()]) :: :ok
  def fetch_after_import(criteria_fun, video_path, kind, release_sidecar_languages)
      when is_function(criteria_fun, 0) do
    Task.Supervisor.start_child(Cinder.Subtitles.TaskSupervisor, fn ->
      safe_fetch(criteria_fun, video_path, kind, release_sidecar_languages)
    end)

    :ok
  end

  defp fetch_languages(criteria_base, languages, video_path, kind) do
    criteria_base = with_moviehash(criteria_base, video_path)
    moviehash = Map.get(criteria_base, :moviehash)

    case Enum.reduce_while(languages, {:ok, local_cache()}, fn language, {:ok, cache} ->
           fetch_language(criteria_base, video_path, kind, language, moviehash, cache)
         end) do
      {:quota_exceeded, _cache} -> :quota_exceeded
      {:ok, _cache} -> :ok
    end
  end

  defp fetch_language(criteria_base, video_path, kind, language, moviehash, cache) do
    case :global.trans(lock_id(video_path), fn ->
           fetch_one(criteria_base, video_path, kind, language, moviehash, cache)
         end) do
      {:quota_exceeded, cache} -> {:halt, {:quota_exceeded, cache}}
      {:ok, cache} -> {:cont, {:ok, cache}}
      :aborted -> {:cont, {:ok, cache}}
    end
  end

  defp fetch_one(criteria_base, video_path, kind, language, moviehash, cache) do
    state = Manifest.read(video_path)

    if Manifest.stable?(state, moviehash, language) and
         sidecar_exists?(sidecar_path(video_path, language)) do
      {:ok, cache}
    else
      search(criteria_base, video_path, kind, language, moviehash, state, cache)
    end
  rescue
    error ->
      Logger.warning("subtitle fetch crashed for #{video_path} (#{language}): #{inspect(error)}")
      {:ok, cache}
  catch
    caught, value ->
      Logger.warning(
        "subtitle fetch #{caught} for #{video_path} (#{language}): #{inspect(value)}"
      )

      {:ok, cache}
  end

  defp search(criteria_base, video_path, kind, language, moviehash, state, cache) do
    criteria = Map.put(criteria_base, :languages, [language])

    case provider().search(criteria) do
      {:ok, results} ->
        case best(results, language) do
          {:hash, result} ->
            provider_result(result, :hash, video_path, kind, language, moviehash, state, cache)

          {:id, result} ->
            provider_result(result, :id, video_path, kind, language, moviehash, state, cache)

          nil ->
            local_fallback(video_path, kind, language, moviehash, state, cache)
        end

      {:error, :quota_exceeded} ->
        Logger.info("OpenSubtitles daily download quota reached; pausing subtitle fetch this run")
        {:quota_exceeded, cache}

      {:error, reason} ->
        Logger.warning(
          "subtitle fetch for #{video_path} (#{language}) failed: #{inspect(reason)}"
        )

        {:ok, cache}

      other ->
        Logger.warning(
          "subtitle search for #{video_path} (#{language}) failed: #{inspect(other)}"
        )

        {:ok, cache}
    end
  end

  defp provider_result(result, match, video_path, kind, language, moviehash, state, cache) do
    target = sidecar_path(video_path, language)
    exists? = sidecar_exists?(target)

    cond do
      not writable?(state, language, exists?) ->
        {:ok, cache}

      match == :id and exists? and origin(state, language) == "opensubtitles_id" ->
        {:ok, cache}

      true ->
        download_and_commit(result, match, video_path, kind, language, moviehash, target, cache)
    end
  end

  defp download_and_commit(result, match, video_path, kind, language, moviehash, target, cache) do
    case provider().download(result.file_id) do
      {:ok, content} ->
        origin = if match == :hash, do: "opensubtitles_hash", else: "opensubtitles_id"
        commit(video_path, kind, language, moviehash, origin, target, content)
        {:ok, cache}

      {:error, :quota_exceeded} ->
        Logger.info("OpenSubtitles daily download quota reached; pausing subtitle fetch this run")
        {:quota_exceeded, cache}

      {:error, reason} ->
        Logger.warning(
          "subtitle download for #{video_path} (#{language}) failed: #{inspect(reason)}"
        )

        {:ok, cache}

      other ->
        Logger.warning(
          "subtitle download for #{video_path} (#{language}) failed: #{inspect(other)}"
        )

        {:ok, cache}
    end
  end

  defp local_fallback(video_path, kind, language, moviehash, state, cache) do
    target = sidecar_path(video_path, language)

    if writable?(state, language, sidecar_exists?(target)) do
      {source, cache} = local_source(video_path, language, cache)

      case source do
        {:direct, content, origin} ->
          commit(video_path, kind, language, moviehash, origin, target, content)

        {:translate, srt} ->
          translate_and_commit(video_path, kind, language, moviehash, target, srt)

        nil ->
          :ok
      end

      {:ok, cache}
    else
      {:ok, cache}
    end
  end

  defp local_source(video_path, language, cache) do
    {tracks, cache} = subtitle_tracks(video_path, cache)

    case Enum.find(tracks, &(track_language(&1) == language and not &1.forced?)) do
      nil ->
        default_or_sidecar(video_path, language, tracks, cache)

      track ->
        case extract(video_path, track) do
          {:ok, content} -> {{:direct, content, "embedded"}, cache}
          :error -> default_or_sidecar(video_path, language, tracks, cache)
        end
    end
  end

  defp default_or_sidecar(video_path, language, tracks, cache) do
    case default_srt(video_path, tracks, cache) do
      {{:ok, srt}, cache} -> {{:translate, srt}, cache}
      {:none, cache} -> sidecar_source(video_path, language, cache)
    end
  end

  defp subtitle_tracks(video_path, %{tracks: :unknown} = cache) do
    tracks =
      case media_info() do
        nil ->
          []

        impl ->
          case impl.subtitle_tracks(video_path) do
            {:ok, tracks} ->
              tracks

            other ->
              Logger.warning("subtitle track probe failed for #{video_path}: #{inspect(other)}")
              []
          end
      end

    {tracks, %{cache | tracks: tracks}}
  end

  defp subtitle_tracks(_video_path, %{tracks: tracks} = cache), do: {tracks, cache}

  defp default_srt(video_path, tracks, %{default_srt: :unknown} = cache) do
    result =
      case Enum.find(tracks, &(&1.default? and not &1.forced?)) do
        nil ->
          :none

        track ->
          with {:ok, content} <- extract(video_path, track),
               {:ok, srt} <- parse_srt(content, video_path) do
            {:ok, srt}
          else
            _ -> :none
          end
      end

    {result, %{cache | default_srt: result}}
  end

  defp default_srt(_video_path, _tracks, %{default_srt: result} = cache), do: {result, cache}

  defp sidecar_source(video_path, language, cache) do
    {sidecars, cache} = srt_sidecars(video_path, cache)

    case Enum.find(sidecars, fn {_path, source_language} -> source_language == language end) do
      {path, _language} ->
        case read(path) do
          {:ok, content} -> {{:direct, content, "translated"}, cache}
          :error -> translation_sidecar(video_path, language, sidecars, cache)
        end

      nil ->
        translation_sidecar(video_path, language, sidecars, cache)
    end
  end

  defp translation_sidecar(video_path, _language, sidecars, %{sidecar_srt: :unknown} = cache) do
    result =
      case sidecars do
        [{path, _language} | _] ->
          with {:ok, content} <- read(path),
               {:ok, srt} <- parse_srt(content, video_path) do
            {:ok, srt}
          else
            _ -> :none
          end

        [] ->
          :none
      end

    result_to_source(result, %{cache | sidecar_srt: result})
  end

  defp translation_sidecar(_video_path, _language, _sidecars, %{sidecar_srt: result} = cache),
    do: result_to_source(result, cache)

  defp result_to_source({:ok, srt}, cache), do: {{:translate, srt}, cache}
  defp result_to_source(:none, cache), do: {nil, cache}

  defp srt_sidecars(video_path, %{sidecars: :unknown} = cache) do
    sidecars = Sidecars.srt_files(video_path)
    {sidecars, %{cache | sidecars: sidecars}}
  end

  defp srt_sidecars(_video_path, %{sidecars: sidecars} = cache), do: {sidecars, cache}

  defp extract(video_path, %{index: index}) do
    case media_info().extract_subtitle(video_path, index) do
      {:ok, content} ->
        {:ok, content}

      other ->
        Logger.warning("subtitle extraction failed for #{video_path}: #{inspect(other)}")
        :error
    end
  end

  defp parse_srt(content, video_path) do
    case Srt.parse(content) do
      {:ok, srt} ->
        {:ok, srt}

      other ->
        Logger.warning("subtitle SRT parse failed for #{video_path}: #{inspect(other)}")
        :error
    end
  end

  defp read(path) do
    with {:ok, path} <- safe_destination(path),
         result <- fs().read(path) do
      case result do
        {:ok, content} ->
          {:ok, content}

        other ->
          Logger.warning("subtitle sidecar read failed: #{inspect(other)}")
          :error
      end
    else
      error ->
        Logger.warning("subtitle sidecar read rejected: #{inspect(error)}")
        :error
    end
  end

  defp translate_and_commit(video_path, kind, language, moviehash, target, srt) do
    case translator().translate(Srt.dialogue(srt), language) do
      {:ok, translated} ->
        case Srt.render(srt, translated) do
          rendered when is_binary(rendered) ->
            commit(video_path, kind, language, moviehash, "translated", target, rendered)

          other ->
            Logger.warning("subtitle render failed for #{video_path}: #{inspect(other)}")
        end

      {:error, reason} ->
        Logger.warning(
          "subtitle translation failed for #{video_path} (#{language}): #{inspect(reason)}"
        )

      other ->
        Logger.warning(
          "subtitle translation failed for #{video_path} (#{language}): #{inspect(other)}"
        )
    end
  end

  defp commit(video_path, kind, language, moviehash, origin, target, content) do
    with {:ok, previous} <- sidecar_snapshot(target),
         :ok <- write_subtitle(target, content) do
      case Manifest.put(video_path, moviehash, language, origin) do
        :ok ->
          Cinder.Library.refresh(kind, video_path)
          Logger.info("wrote #{language} subtitle for #{video_path}")

        error ->
          rollback_sidecar(target, previous)

          Logger.warning(
            "subtitle provenance write failed for #{video_path} (#{language}): #{inspect(error)}"
          )
      end
    else
      error ->
        Logger.warning("subtitle write failed for #{video_path} (#{language}): #{inspect(error)}")
    end
  end

  defp sidecar_snapshot(target) do
    with {:ok, target} <- safe_destination(target) do
      case fs().read(target) do
        {:ok, content} -> {:ok, {:existing, content}}
        {:error, :enoent} -> {:ok, :missing}
        error -> {:error, error}
      end
    end
  end

  defp rollback_sidecar(target, :missing) do
    case safe_remove(target) do
      :ok -> :ok
      error -> Logger.warning("subtitle rollback rejected: #{inspect(error)}")
    end
  end

  defp rollback_sidecar(target, {:existing, content}) do
    case write_subtitle(target, content) do
      :ok -> :ok
      error -> Logger.warning("subtitle rollback failed for #{target}: #{inspect(error)}")
    end
  end

  defp write_subtitle(target, content) do
    temporary =
      Path.join(
        Path.dirname(target),
        ".cinder-subtitle-#{System.unique_integer([:positive])}"
      )

    with {:ok, target} <- safe_destination(target),
         {:ok, temporary} <- safe_destination(temporary),
         :ok <- fs().write(temporary, content) do
      rename_subtitle(temporary, target)
    end
  end

  defp rename_subtitle(temporary, target) do
    result =
      with {:ok, temporary} <- safe_destination(temporary),
           {:ok, target} <- safe_destination(target) do
        fs().rename(temporary, target)
      end

    if result != :ok, do: safe_remove(temporary)
    result
  end

  defp best(results, language) do
    candidates =
      Enum.filter(results, fn result ->
        case Map.get(result, :language) do
          candidate_language when is_binary(candidate_language) ->
            String.downcase(candidate_language) == language and
              not Map.get(result, :hearing_impaired, false) and
              not Map.get(result, :ai_translated, false) and not is_nil(Map.get(result, :file_id))

          _ ->
            false
        end
      end)

    case Enum.filter(candidates, &Map.get(&1, :moviehash_match, false)) do
      [] -> candidates |> Enum.max_by(&Map.get(&1, :downloads, 0), fn -> nil end) |> tag(:id)
      matches -> matches |> Enum.max_by(&Map.get(&1, :downloads, 0)) |> tag(:hash)
    end
  end

  defp tag(nil, _match), do: nil
  defp tag(result, match), do: {match, result}

  defp writable?(state, language, exists?), do: not exists? or Manifest.managed?(state, language)
  defp origin(state, language), do: get_in(state, [:tracks, language, :origin])

  defp sidecar_exists?(path) do
    with {:ok, path} <- safe_destination(path),
         {:ok, _stat} <- fs().lstat(path),
         do: true,
         else: (_ -> false)
  end

  defp track_language(track), do: Map.get(track, :language, "") |> String.downcase()

  defp with_moviehash(criteria_base, video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, moviehash} -> Map.put(criteria_base, :moviehash, moviehash)
      _ -> criteria_base
    end
  end

  defp safe_fetch(criteria_fun, video_path, kind, release_sidecar_languages) do
    mark_release_sidecars(video_path, release_sidecar_languages)
    fetch_missing(criteria_fun.(), video_path, kind)
  rescue
    error -> Logger.warning("subtitle fetch crashed for #{video_path}: #{inspect(error)}")
  catch
    caught, value ->
      Logger.warning("subtitle fetch #{caught} for #{video_path}: #{inspect(value)}")
  end

  defp mark_release_sidecars(video_path, languages) do
    moviehash = current_moviehash(video_path)

    Enum.each(Enum.uniq(languages), &mark_release_sidecar(video_path, moviehash, &1))

    :ok
  end

  defp mark_release_sidecar(video_path, moviehash, language) do
    :global.trans(lock_id(video_path), fn ->
      target = sidecar_path(video_path, language)
      put_release_sidecar(video_path, moviehash, language, target)
    end)
  end

  defp put_release_sidecar(video_path, moviehash, language, target) do
    if sidecar_exists?(target) do
      case Manifest.put(video_path, moviehash, language, "release_sidecar") do
        :ok -> :ok
        other -> Logger.warning("subtitle manifest write failed for #{target}: #{inspect(other)}")
      end
    end
  end

  defp current_moviehash(video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, moviehash} -> moviehash
      _ -> nil
    end
  end

  defp lock_id(video_path), do: {{__MODULE__, video_path}, self()}

  defp local_cache,
    do: %{tracks: :unknown, default_srt: :unknown, sidecars: :unknown, sidecar_srt: :unknown}

  defp provider, do: Application.fetch_env!(:cinder, :subtitles_provider)
  defp translator, do: Application.fetch_env!(:cinder, :subtitles_translator)
  defp media_info, do: Application.get_env(:cinder, :media_info)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)

  defp safe_destination(path),
    do: path_policy().destination(path, Settings.library_roots(), filesystem: fs())

  defp safe_remove(path) do
    with :ok <-
           path_policy().deletable_file(path, Settings.library_roots(), filesystem: fs()),
         do: fs().rm(path)
  end

  defp provider_config,
    do: Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
end
