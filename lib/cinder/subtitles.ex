defmodule Cinder.Subtitles do
  @moduledoc """
  Best-effort subtitle coordinator for imported videos.

  It records Cinder-owned sidecars in a hidden manifest, so hash-matched provider results are
  stable while ID, embedded, translated, and release sidecars remain eligible for later upgrades.
  """

  require Logger
  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.{PathPolicy, Sidecars}
  alias Cinder.Settings
  alias Cinder.Subtitles.{Fetcher, Manifest, Moviehash, Srt}
  alias Cinder.Subtitles.Sync
  alias Cinder.Subtitles.Sync.Timing
  alias Cinder.Subtitles.Sync.Worker

  @doc "Subtitle-search criteria for a movie: imdb + tmdb id (the provider prefers imdb)."
  @spec movie_criteria(Movie.t()) :: map()
  def movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id}),
    do: %{imdb_id: imdb_id, tmdb_id: tmdb_id}

  @doc """
  Subtitle-search criteria for an episode: series tmdb id + season/episode numbers.

  An A6 alternate-numbering (scene) coordinate mapping this episode overrides the canonical
  TMDB season/episode: OpenSubtitles is scene-numbered like the release indexers, so an
  episode-group series (e.g. Frieren's TMDB S01E29 = scene S02E01) would otherwise miss every
  subtitle (issue #143). Requires `episode_coordinates` preloaded; an unloaded association falls
  back to canonical numbering — the callers that actually search preload it.
  """
  @spec episode_criteria(Episode.t()) :: map()
  def episode_criteria(
        %Episode{
          episode_number: number,
          season: %{season_number: season, series: %Series{tmdb_id: tmdb_id}}
        } = episode
      ) do
    {q_season, q_episode} = scene_numbering(episode) || {season, number}
    %{tmdb_id: tmdb_id, season: q_season, episode: q_episode}
  end

  # The scene {season, episode} from the highest-precedence "scene" coordinate mapping this
  # episode, or nil. Scene coordinates are 1:1 (one "SxxEyy" per episode); precedence ties are
  # broken by taking the max (manual > curated > inferred), matching AnimeResolver.
  @scene_precedence %{inferred: 0, curated: 1, manual: 2}

  defp scene_numbering(%Episode{episode_coordinates: coordinates}) when is_list(coordinates) do
    coordinates
    |> Enum.filter(&(&1.scheme == "scene"))
    |> Enum.max_by(&Map.fetch!(@scene_precedence, &1.precedence), fn -> nil end)
    |> case do
      nil -> nil
      coordinate -> Episode.season_and_episode_from_code(coordinate.canonical_value)
    end
  end

  defp scene_numbering(_episode), do: nil

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

  @doc """
  Runs subtitle work off the import path and marks current release sidecars as Cinder-managed.
  Enqueued on the single serializing `Cinder.Subtitles.Fetcher` — one fetch in flight at a time —
  so a bulk import (a whole series added at once) can't burst OpenSubtitles into rate-limiting it
  (issue #80).
  """
  @spec fetch_after_import((-> map()), String.t(), :movies | :tv, [String.t()]) :: :ok
  def fetch_after_import(criteria_fun, video_path, kind, release_sidecar_languages)
      when is_function(criteria_fun, 0) do
    Fetcher.enqueue(criteria_fun, video_path, kind, release_sidecar_languages)
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
    target = sidecar_path(video_path, language)

    if Manifest.managed?(state, language), do: normalize_sidecar_mode(target)

    if Manifest.stable?(state, moviehash, language) and sidecar_exists?(target) do
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

      match == :id and exists? and
          (origin(state, language) == "opensubtitles_id" or
             keep_verified?(state, moviehash, language)) ->
        {:ok, cache}

      true ->
        download_and_commit(result, match, video_path, kind, language, moviehash, target, cache)
    end
  end

  defp download_and_commit(result, match, video_path, kind, language, moviehash, target, cache) do
    case provider().download(result.file_id) do
      {:ok, content} ->
        origin = if match == :hash, do: "opensubtitles_hash", else: "opensubtitles_id"

        case Timing.validate(content, Path.extname(target)) do
          :ok ->
            commit(video_path, kind, language, moviehash, origin, target, content)

          {:error, reason} ->
            Logger.warning(
              "subtitle download for #{video_path} (#{language}) failed validation: #{inspect(reason)}"
            )
        end

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
    exists? = sidecar_exists?(target)

    if writable?(state, language, exists?) do
      {source, cache} = local_source(video_path, language, target, cache)

      case source do
        {:direct, content, origin} ->
          commit(video_path, kind, language, moviehash, origin, target, content)

        {:translate, srt} when not exists? ->
          translate_and_commit(video_path, kind, language, moviehash, target, srt)

        {:translate, _srt} ->
          :ok

        nil ->
          :ok
      end

      {:ok, cache}
    else
      {:ok, cache}
    end
  end

  defp local_source(video_path, language, target, cache) do
    {tracks, cache} = subtitle_tracks(video_path, cache)

    # Language.raw_track_satisfies?/2, not exact equality against the raw track code: a "cn"
    # (Cantonese) request must still accept a generically-tagged "chi"/"zho" track (#573), the
    # same forward-tolerance rule Cinder.Subtitles.Sync.Reference.select/4 uses. An unambiguous
    # match ("cn"/"yue", "zh"/"cmn") is preferred over a generic-alias one ("chi"/"zho", tolerated
    # by both) - the ambiguous track might genuinely be the other language (#573 review).
    candidates =
      tracks
      |> Enum.filter(&(Language.raw_track_satisfies?(language, &1.language) and not &1.forced?))
      |> Enum.sort_by(&if(Language.exact_track?(language, &1.language), do: 0, else: 1))

    # Try every matching candidate in preference order, not just the best one - an unextractable
    # exact track must not give up before trying a usable, merely-ambiguous one (#575), mirroring
    # Reference.select/4's existing cascade.
    case Enum.find_value(candidates, &extracted(video_path, &1)) do
      nil -> default_or_sidecar(video_path, language, target, tracks, cache)
      content -> {{:direct, content, "embedded"}, cache}
    end
  end

  defp extracted(video_path, track) do
    case extract(video_path, track) do
      {:ok, content} -> content
      :error -> nil
    end
  end

  defp default_or_sidecar(video_path, language, target, tracks, cache) do
    case default_srt(video_path, tracks, cache) do
      {{:ok, srt}, cache} -> {{:translate, srt}, cache}
      {:none, cache} -> sidecar_source(video_path, language, target, cache)
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

  defp sidecar_source(video_path, language, target, cache) do
    {sidecars, cache} = srt_sidecars(video_path, cache)
    candidates = Enum.reject(sidecars, fn {path, _language} -> same_path?(path, target) end)

    case Enum.find(candidates, fn {_path, source_language} -> source_language == language end) do
      {path, _language} ->
        case read(path) do
          {:ok, content} -> {{:direct, content, "translated"}, cache}
          :error -> translation_sidecar(video_path, language, candidates, cache)
        end

      nil ->
        translation_sidecar(video_path, language, candidates, cache)
    end
  end

  defp same_path?(a, b), do: Path.expand(a) == Path.expand(b)

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
    previous_state = Manifest.read(video_path)

    previous_sync =
      Manifest.replacement_cleanup_sync(previous_state, language) ||
        Manifest.sync(previous_state, language)

    with {:ok, previous} <- sidecar_snapshot(target),
         :ok <- write_subtitle(target, content) do
      case Manifest.put(
             video_path,
             moviehash,
             language,
             origin,
             target,
             sha256(content),
             previous_sync
           ) do
        :ok ->
          reconcile_replaced_backup(video_path, language, target, previous_sync)
          after_commit(video_path, kind, language, origin)

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

  defp cleanup_replaced_backup(video_path, language, target, previous_sync) do
    case Sync.discard_replacement(video_path, language, target, previous_sync) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("subtitle backup cleanup failed for #{target}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp reconcile_replaced_backup(_video_path, _language, _target, nil), do: :ok

  defp reconcile_replaced_backup(video_path, language, target, previous_sync) do
    with :ok <- cleanup_replaced_backup(video_path, language, target, previous_sync),
         :ok <- Manifest.clear_replacement_cleanup(video_path, language) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "subtitle replacement cleanup remains journaled for #{target}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp after_commit(video_path, kind, language, origin) do
    if origin in ["opensubtitles_hash", "opensubtitles_id"] do
      Worker.enqueue_after_download(video_path, kind)
    end

    Cinder.Library.refresh(kind, video_path)
    Logger.info("wrote #{language} subtitle for #{video_path}")
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

    result =
      with {:ok, target} <- safe_destination(target),
           {:ok, temporary} <- safe_destination(temporary),
           :ok <- fs().write(temporary, content),
           :ok <- fs().chmod(temporary, 0o644) do
        rename_subtitle(temporary, target, IO.iodata_to_binary(content))
      end

    if result != :ok, do: safe_remove(temporary)
    result
  end

  defp normalize_sidecar_mode(target) do
    case safe_destination(target) do
      {:ok, target} ->
        case fs().chmod(target, 0o644) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          error ->
            Logger.warning("subtitle permission repair failed for #{target}: #{inspect(error)}")
        end

      error ->
        Logger.warning("subtitle permission repair rejected: #{inspect(error)}")
    end
  end

  defp rename_subtitle(temporary, target, expected) do
    result =
      with {:ok, temporary} <- safe_destination(temporary),
           {:ok, target} <- safe_destination(target) do
        fs().rename(temporary, target)
      end

    case result do
      :ok ->
        :ok

      {:error, {:effect_committed, "rename", _reason}} = error ->
        verified = fs().read(target) == {:ok, expected}
        _ = safe_remove(temporary)
        if verified, do: :ok, else: error

      error ->
        _ = safe_remove(temporary)
        error
    end
  end

  defp best(results, language) do
    candidates =
      Enum.filter(results, fn result ->
        candidate_language = Map.get(result, :language)

        is_binary(candidate_language) and String.downcase(candidate_language) == language and
          not Map.get(result, :hearing_impaired, false) and
          not Map.get(result, :ai_translated, false) and not is_nil(Map.get(result, :file_id))
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

  defp with_moviehash(criteria_base, video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, moviehash} -> Map.put(criteria_base, :moviehash, moviehash)
      _ -> criteria_base
    end
  end

  @doc """
  Runs one import's subtitle fetch synchronously (the body the `Fetcher` executes per queued
  unit). `criteria_fun` runs INSIDE this rescue/catch so a preload/criteria surprise or a
  provider blow-up crashes nothing — it logs and the caller (the `Fetcher`) moves on to the next
  queued fetch.
  """
  @spec fetch_now((-> map()), String.t(), :movies | :tv, [String.t()]) :: :ok | :quota_exceeded
  def fetch_now(criteria_fun, video_path, kind, release_sidecar_languages) do
    mark_release_sidecars(video_path, release_sidecar_languages)
    fetch_missing(criteria_fun.(), video_path, kind)
  rescue
    error -> Logger.warning("subtitle fetch crashed for #{video_path}: #{inspect(error)}")
  catch
    caught, value ->
      Logger.warning("subtitle fetch #{caught} for #{video_path}: #{inspect(value)}")
  end

  @doc """
  Marks each of `languages`' canonical sidecars for `video_path` as Cinder-managed in the
  manifest (origin `"release_sidecar"`), recomputing the moviehash fresh from the file. Used both
  on the normal import path (via `fetch_now/4`) and by `Cinder.Library.Backfill` to repair a row
  whose sidecars were never registered (issue #128).
  """
  @spec mark_release_sidecars(String.t(), [String.t()] | nil) :: :ok
  def mark_release_sidecars(_video_path, languages) when languages in [nil, []], do: :ok

  def mark_release_sidecars(video_path, languages) do
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
    state = Manifest.read(video_path)

    if sidecar_exists?(target) and not keep_registered?(state, moviehash, language, target) do
      case Manifest.put(
             video_path,
             moviehash || state.video_moviehash,
             language,
             "release_sidecar",
             target
           ) do
        :ok -> :ok
        other -> Logger.warning("subtitle manifest write failed for #{target}: #{inspect(other)}")
      end
    end
  end

  # A hash-verified (stable) entry is the sweeper's finished work; re-marking it as
  # release-provided — and rewriting the manifest's video_moviehash wholesale — would downgrade
  # it and force a redo, so Backfill re-runs and import re-marks skip it. An uncomputable current
  # hash can't prove the file changed, so the entry is kept then too; a genuinely changed hash
  # falls through and re-marks the sidecar as release-provided. The `moviehash ||
  # state.video_moviehash` above is the same stance for the file-level hash: a sibling language's
  # write with an uncomputable hash must not wipe the stored hash a verified language's
  # stability rides on.
  defp keep_verified?(state, moviehash, language) do
    Manifest.verified?(state, language) and
      (is_nil(moviehash) or Manifest.stable?(state, moviehash, language))
  end

  # `Manifest.put` here always writes a fresh track carrying only `backup_tombstone` forward —
  # no managed digest, sync record, or cleanup journal (issue #527). Re-registering an
  # already-provider-owned (`opensubtitles_hash`/`opensubtitles_id`) sidecar whose current bytes
  # still match what Cinder last wrote — either the original download (`managed_sha256`) or a
  # legitimate later correction (`sync.applied_sha256`) — would silently drop its synchronization
  # provenance for no reason, removing it from `Sync.discover/1`. A track with an in-progress
  # reset or replacement cleanup journal is protected the same way regardless of its bytes:
  # erasing that journal mid-recovery would strand the crash-recovery state it exists for.
  defp keep_registered?(state, moviehash, language, target) do
    keep_verified?(state, moviehash, language) or
      active_cleanup_journal?(state, language) or
      unchanged_provider_track?(state, language, target)
  end

  defp active_cleanup_journal?(state, language) do
    not is_nil(get_in(state, [:tracks, language, :reset_cleanup_sync])) or
      not is_nil(get_in(state, [:tracks, language, :replacement_cleanup_sync]))
  end

  defp unchanged_provider_track?(state, language, target) do
    case get_in(state, [:tracks, language]) do
      %{origin: origin, managed_sha256: managed_sha256} = track
      when origin in ["opensubtitles_hash", "opensubtitles_id"] and is_binary(managed_sha256) ->
        matches_recorded_bytes?(current_sidecar_sha256(target), managed_sha256, track)

      _ ->
        false
    end
  end

  # A failed read (`nil`) must never count as a match: a track carrying no `sync` yet has no
  # `sync.applied_sha256` either, and comparing two absent values would otherwise silently
  # "prove" an unreadable sidecar unchanged.
  defp matches_recorded_bytes?(nil, _managed_sha256, _track), do: false

  defp matches_recorded_bytes?(current, managed_sha256, track) do
    current == managed_sha256 or current == get_in(track, [:sync, :applied_sha256])
  end

  defp current_sidecar_sha256(target) do
    with {:ok, target} <- safe_destination(target),
         {:ok, content} <- fs().read(target) do
      sha256(content)
    else
      _ -> nil
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

  defp sha256(content) do
    content
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp provider, do: Application.fetch_env!(:cinder, :subtitles_provider)
  defp translator, do: Application.fetch_env!(:cinder, :subtitles_translator)
  defp media_info, do: Application.get_env(:cinder, :media_info)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)

  # Book roots must never authorize subtitle sidecar writes or deletes.
  defp safe_destination(path),
    do: path_policy().destination(path, Settings.video_library_roots(), filesystem: fs())

  defp safe_remove(path) do
    with :ok <-
           path_policy().deletable_file(path, Settings.video_library_roots(), filesystem: fs()),
         do: fs().rm(path)
  end

  defp provider_config,
    do: Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
end
