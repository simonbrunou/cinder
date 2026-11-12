defmodule Cinder.Subtitles do
  @moduledoc """
  Best-effort subtitle coordinator for imported videos.

  It records Cinder-owned sidecars in a hidden manifest, so hash-matched provider results are
  stable while ID, embedded, translated, and release sidecars remain eligible for later upgrades.
  """

  require Logger
  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.Sidecars
  alias Cinder.Subtitles.{Fetcher, Manifest, Moviehash, OwnTrack, SidecarTransaction}
  alias Cinder.Subtitles.{Srt, TrackProbe, TrackRejection}
  alias Cinder.Subtitles.Sync.{Timing, Worker}

  # Book roots must never authorize subtitle sidecar reads, writes or deletes.
  import Cinder.Subtitles.SafeFile, only: [fs: 0, safe_destination: 1, sha256: 1]

  @doc """
  Subtitle-search criteria for a movie: imdb + tmdb id (the provider prefers imdb), plus the
  subtitle languages the import probe found in the file (`Cinder.Subtitles.OwnTrack`).
  """
  @spec movie_criteria(Movie.t()) :: map()
  def movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id} = movie),
    do: %{
      imdb_id: imdb_id,
      tmdb_id: tmdb_id,
      embedded_subtitles: movie.imported_embedded_subtitles
    }

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

    %{
      tmdb_id: tmdb_id,
      season: q_season,
      episode: q_episode,
      embedded_subtitles: episode.imported_embedded_subtitles
    }
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

  @typedoc """
  The release sidecars an import hands its subtitle task: `languages:`, the sidecar languages it
  recorded next to the file, and `placed:`, the sidecar paths its commit placed there
  (`Cinder.Library.Sidecars.link/2`). Either may be absent. Any other key, or a bare language
  list, raises in `fetch_after_import/4`; `fetch_now/4` logs it and skips the fetch.
  """
  @type release_sidecars :: [languages: [String.t()] | nil, placed: [String.t()]]

  @doc """
  Runs subtitle work off the import path and marks the release sidecars `fetch_now/4` may mark
  as Cinder-managed. Enqueued on the single serializing `Cinder.Subtitles.Fetcher` — one fetch in
  flight at a time — so a bulk import (a whole series added at once) can't burst OpenSubtitles
  into rate-limiting it (issue #80).
  """
  @spec fetch_after_import((-> map()), String.t(), :movies | :tv, release_sidecars()) :: :ok
  def fetch_after_import(criteria_fun, video_path, kind, release_sidecars)
      when is_function(criteria_fun, 0) do
    Fetcher.enqueue(criteria_fun, video_path, kind, release_sidecars!(release_sidecars))
  end

  defp release_sidecars!(release_sidecars),
    do: Keyword.validate!(release_sidecars, languages: nil, placed: [])

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
      case own_track(criteria_base, video_path, kind, language, moviehash, state, cache) do
        {:committed, cache} ->
          {:ok, cache}

        {:none, cache} ->
          search(criteria_base, video_path, kind, language, moviehash, state, cache)
      end
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

  # The video's own full track in `language` replaces a downloaded sidecar (spec 069, option C).
  # Only for a file whose import probe saw a stream in that language, so the track probe (a full
  # read of the file) does not run on every sweep for every video; once committed it is stable for
  # this moviehash and never re-extracted, and once its content is rejected it is not extracted
  # again for this moviehash either (`TrackRejection`). A sidecar the operator retimed by hand is
  # kept.
  #
  # A track found at import is timed like a fresh download (shot changes detected); one a library
  # sweep finds for a file already in the library is queued behind other work with cached shot
  # changes only, since the first sweep after this change finds one for thousands of files.
  defp own_track(criteria_base, video_path, kind, language, moviehash, state, cache) do
    target = sidecar_path(video_path, language)

    if OwnTrack.wanted?(criteria_base, language) and own_track_time?(criteria_base) and
         writable?(state, language, sidecar_exists?(target)) and
         get_in(state, [:tracks, language, :sync, :method]) != "manual" do
      {tracks, cache} = subtitle_tracks(video_path, moviehash, cache)
      enqueue = if Map.get(criteria_base, :fresh), do: :fresh, else: :background
      track = OwnTrack.select(tracks, language)

      case timed_content(video_path, moviehash, track, cache) do
        {{:ok, content}, cache} ->
          commit(video_path, kind, language, moviehash, "own_track", target, content,
            enqueue: enqueue
          )

          {:committed, cache}

        {:none, cache} ->
          {:none, cache}
      end
    else
      {:none, cache}
    end
  end

  # A track's content once it passed the timing check, which the own track, the embedded fallback
  # and the default track as a translation source (`default_srt/4`) all run on the same extracted
  # bytes. A rejection is stored per moviehash and track, so none of them extracts the track again
  # for this file (`TrackRejection` `:timing`). It is also kept for the fetch, so a file without a
  # moviehash is checked and logged once per fetch.
  defp timed_content(_video_path, _moviehash, nil, cache), do: {:none, cache}

  defp timed_content(video_path, moviehash, track, cache) do
    if MapSet.member?(cache.timing_rejected, track.index) or
         TrackRejection.rejected?(moviehash, track.index, :timing) do
      {:none, cache}
    else
      case extract(video_path, track, cache) do
        {{:ok, content}, cache} -> validated_content(content, video_path, moviehash, track, cache)
        {:error, cache} -> {:none, cache}
      end
    end
  end

  defp validated_content(content, video_path, moviehash, track, cache) do
    case Timing.validate(content, ".srt") do
      :ok ->
        {{:ok, content}, cache}

      {:error, reason} ->
        Logger.info(
          "subtitle track #{track.index} of #{video_path} failed the timing check: " <>
            inspect(reason)
        )

        TrackRejection.reject(moviehash, track.index, :timing)
        {:none, %{cache | timing_rejected: MapSet.put(cache.timing_rejected, track.index)}}
    end
  end

  # A library sweep bounds the time it spends on own tracks (`Cinder.Subtitles.Sweeper`); an import
  # is never bounded.
  defp own_track_time?(%{own_track_until: until}), do: System.monotonic_time(:millisecond) < until
  defp own_track_time?(_criteria), do: true

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

  # The search ran first, so an OpenSubtitles match still replaces an embedded sidecar.
  defp local_fallback(video_path, kind, language, moviehash, state, cache) do
    target = sidecar_path(video_path, language)
    exists? = sidecar_exists?(target)

    if writable?(state, language, exists?) do
      exists? = exists? and kept?(video_path, kind, language, state, target)
      held = if exists?, do: Manifest.embedded_track(state, moviehash, language)

      {source, cache} =
        local_source(video_path, language, moviehash, target, exists?, held, cache)

      case source do
        {:embedded, content, index} ->
          commit(video_path, kind, language, moviehash, "embedded", target, content,
            source_track: index
          )

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

  @sync_records [:sync, :sync_invalid?, :reset_cleanup_sync, :reset_cleanup_sync_invalid?]

  # Whether the fetch goes on with the target held, as before this check: it then gives way only to
  # an embedded track `ranked_ahead/2` lets through, whatever bytes it holds. An embedded sidecar
  # is checked on its own bytes, whether or not its entry records the file and track it came from:
  # one committed before the timing check (#1072) could otherwise stay until an OpenSubtitles match
  # replaced it, since a sweep tries only the candidates ranked ahead of its track (#1110). One
  # that fails is removed, and the fetch goes on as for a missing target: no sidecar beats one a
  # player may mis-render, and the track stays in the video. Only the bytes Cinder wrote are
  # removed: a sidecar edited since, one that cannot be read and one that changed before the
  # removal stay held. So does one with a record that only `Cinder.Subtitles.Sync` writes
  # (`@sync_records`). A manual one is the operator's retime, which the own-track path keeps too,
  # and Sync never handles an embedded sidecar, so any such record there is unexplained and may
  # name a backup. A backup tombstone and a replacement's cleanup journal come with a fetched
  # replacement, so `SidecarTransaction.remove/3` keeps them.
  defp kept?(video_path, kind, language, state, target) do
    with %{origin: "embedded"} = track <- state.tracks[language],
         false <- Enum.any?(@sync_records, &Map.has_key?(track, &1)),
         {:ok, content} <- read(target),
         true <- sha256(content) == track[:managed_sha256],
         {:error, reason} <- Timing.validate(content, Path.extname(target)) do
      remove_embedded(video_path, kind, language, target, content, reason)
    else
      _kept -> true
    end
  end

  # An error can come after the sidecar is gone, so the disk tells whether it stays.
  defp remove_embedded(video_path, kind, language, target, content, reason) do
    sidecar = %{video_path: video_path, sidecar_path: target, language: language}

    case SidecarTransaction.remove(sidecar, content, "embedded") do
      :ok ->
        removed(video_path, kind, language, target, reason)

      {:error, error} ->
        Logger.warning("subtitle removal failed for #{target}: #{inspect(error)}")
        sidecar_exists?(target) or removed(video_path, kind, language, target, reason)
    end
  end

  defp removed(video_path, kind, language, target, reason) do
    Cinder.Library.refresh(kind, video_path)

    Logger.info(
      "removed the embedded subtitle #{target} (#{language}): it failed the timing check: " <>
        inspect(reason)
    )

    false
  end

  # `held` is the track the target was extracted from, when it came out of this very file.
  defp local_source(video_path, language, moviehash, target, exists?, held, cache) do
    {tracks, cache} = subtitle_tracks(video_path, moviehash, cache)

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
    #
    # Each candidate must pass the timing check the own track passes (#1072). One it rejects is
    # passed over like one that did not extract, and is not extracted again for this file.
    #
    # A target already extracted from this file is not extracted and committed again (#861). Only
    # the candidates ranked ahead of its track are tried: a busy disk fails an extraction the way a
    # damaged file does, and must not leave a lesser track in place for good (#1071).
    #
    # With the target in place nothing else is looked for. A translation could not replace it, so
    # the default track is not extracted for one (#861), and a sidecar in the same language would
    # be copied over it again on every sweep (#1070).
    case first_passing(video_path, moviehash, ranked_ahead(candidates, held), cache) do
      {nil, cache} when exists? ->
        {nil, cache}

      {nil, cache} ->
        default = default_track(tracks, candidates, moviehash, cache)
        default_or_sidecar(video_path, language, moviehash, target, default, cache)

      {{index, content}, cache} ->
        {{:embedded, content, index}, cache}
    end
  end

  # None when the held track is the first candidate. All of them when the target records no track,
  # or one that is no candidate today: the cascade then runs once and records the track it takes.
  defp ranked_ahead(candidates, nil), do: candidates

  defp ranked_ahead(candidates, held) do
    case Enum.find_index(candidates, &(&1.index == held)) do
      nil -> candidates
      position -> Enum.take(candidates, position)
    end
  end

  # The first candidate that extracts and passes the timing check.
  defp first_passing(video_path, moviehash, candidates, cache) do
    Enum.reduce_while(candidates, {nil, cache}, fn track, {nil, cache} ->
      case timed_content(video_path, moviehash, track, cache) do
        {{:ok, content}, cache} -> {:halt, {{track.index, content}, cache}}
        {:none, cache} -> {:cont, {nil, cache}}
      end
    end)
  end

  # The default track is only a translation source, so it is not extracted when no translation
  # can come of it (#861). Every sweep used to extract it and drop the result. With no translator,
  # the sidecars are looked at as if there were no default track. So are they without a default
  # track (`default_track/4`), and when its content does not parse or fails the timing check.
  defp default_or_sidecar(video_path, language, moviehash, target, track, cache) do
    if is_nil(track) or not translator().configured?() do
      sidecar_source(video_path, language, target, cache)
    else
      case default_srt(video_path, moviehash, track, cache) do
        {{:ok, srt}, cache} -> {{:translate, srt}, cache}
        {:none, cache} -> sidecar_source(video_path, language, target, cache)
      end
    end
  end

  # None when the default track did not parse for this moviehash, when the timing check rejected
  # it, or when it is itself one of the candidates in the wanted language. The cascade passed such
  # a candidate over because it did not extract or failed the timing check. A translation keeps
  # the cue times of its source, so translating it would write the rejected times as the sidecar
  # (#1072). The timing rejection may come from the own track, an embedded candidate or an
  # earlier translation (#1109), stored for this moviehash or kept for this fetch.
  defp default_track(tracks, candidates, moviehash, cache) do
    track = Enum.find(tracks, &(&1.default? and not &1.forced?))

    cond do
      is_nil(track) or track in candidates -> nil
      TrackRejection.rejected?(moviehash, track.index, :srt) -> nil
      MapSet.member?(cache.timing_rejected, track.index) -> nil
      TrackRejection.rejected?(moviehash, track.index, :timing) -> nil
      true -> track
    end
  end

  # Kept per file (`TrackProbe`): the probe reads the whole file, and the own-track check asks on
  # every sweep.
  defp subtitle_tracks(video_path, moviehash, %{tracks: :unknown} = cache) do
    tracks = probe_tracks(media_info(), video_path, moviehash)
    {tracks, %{cache | tracks: tracks}}
  end

  defp subtitle_tracks(_video_path, _moviehash, %{tracks: tracks} = cache), do: {tracks, cache}

  defp probe_tracks(nil, _video_path, _moviehash), do: []

  defp probe_tracks(impl, video_path, moviehash) do
    case TrackProbe.tracks(moviehash, fn -> impl.subtitle_tracks(video_path) end) do
      {:ok, tracks} ->
        tracks

      other ->
        Logger.warning("subtitle track probe failed for #{video_path}: #{inspect(other)}")
        []
    end
  end

  defp default_srt(video_path, moviehash, track, %{default_srt: :unknown} = cache) do
    {result, cache} =
      case extract(video_path, track, cache) do
        {{:ok, content}, cache} ->
          translation_source(content, video_path, moviehash, track, cache)

        {:error, cache} ->
          {:none, cache}
      end

    {result, %{cache | default_srt: result}}
  end

  defp default_srt(_video_path, _moviehash, _track, %{default_srt: result} = cache),
    do: {result, cache}

  # The parse runs first, so content that fails both checks is stored as `:srt`, as before the
  # timing check (#1109). Content that parses must pass the timing check too: the translation
  # keeps its cue times.
  defp translation_source(content, video_path, moviehash, track, cache) do
    with {:ok, srt} <- parse_srt(content, video_path),
         {{:ok, _content}, cache} <-
           validated_content(content, video_path, moviehash, track, cache) do
      {{:ok, srt}, cache}
    else
      :error ->
        TrackRejection.reject(moviehash, track.index, :srt)
        {:none, cache}

      {:none, cache} ->
        {:none, cache}
    end
  end

  # A same-language sidecar with no flag wins over a hearing-impaired one, as in
  # `Cinder.Subtitles.OwnTrack.select/2`. One that cannot be read or fails the timing check is
  # passed over for the next one (#1109), as the embedded cascade passes over a track. With none
  # left, `translation_sidecar/4` looks for a translation source among the other languages.
  defp sidecar_source(video_path, language, target, cache) do
    {sidecars, cache} = srt_sidecars(video_path, cache)

    candidates =
      Enum.reject(sidecars, fn {path, _language, _flags} -> same_path?(path, target) end)

    copy =
      candidates
      |> Enum.filter(&in_language?(&1, language))
      |> Enum.sort_by(fn {_path, _language, flags} -> flags != [] end)
      |> Enum.find_value(fn {path, _language, _flags} ->
        case timed_sidecar(path) do
          {:ok, content} -> content
          :error -> nil
        end
      end)

    if copy do
      {{:direct, copy, "translated"}, cache}
    else
      translation_sidecar(video_path, language, candidates, cache)
    end
  end

  defp same_path?(a, b), do: Path.expand(a) == Path.expand(b)

  # The language match the copy uses. A sidecar whose name holds no language reads as `und`, which
  # no wanted language equals.
  defp in_language?({_path, source_language, _flags}, language), do: source_language == language

  # The first sidecar in listing order that is in another language and reads, passes the timing
  # check and parses (#1270). One in the wanted language is left out: the copy passed it over, and
  # translating it would write it into its own language with origin `translated`. The pick is made
  # for each wanted language, so the source picked for one is never taken for the language it is
  # in.
  defp translation_sidecar(video_path, language, candidates, cache) do
    candidates
    |> Enum.reject(&in_language?(&1, language))
    |> Enum.reduce_while({nil, cache}, fn {path, _language, _flags}, {nil, cache} ->
      case sidecar_srt(video_path, path, cache) do
        {{:ok, srt}, cache} -> {:halt, {{:translate, srt}, cache}}
        {:none, cache} -> {:cont, {nil, cache}}
      end
    end)
  end

  # Each sidecar's result is kept for the fetch, a failure included, so the translation sources of
  # all wanted languages read and check a sidecar once.
  defp sidecar_srt(video_path, path, %{sidecar_srt: results} = cache) do
    case Map.fetch(results, path) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result =
          with {:ok, content} <- timed_sidecar(path),
               {:ok, srt} <- parse_srt(content, video_path),
               do: {:ok, srt},
               else: (:error -> :none)

        {result, %{cache | sidecar_srt: Map.put(results, path, result)}}
    end
  end

  # A forced sidecar is never a source (#1070): like a forced track, it holds only the lines the
  # audio does not carry.
  defp srt_sidecars(video_path, %{sidecars: :unknown} = cache) do
    sidecars =
      for {path, language} <- Sidecars.srt_files(video_path),
          flags = Sidecars.flags(path),
          "forced" not in flags,
          do: {path, language, flags}

    {sidecars, %{cache | sidecars: sidecars}}
  end

  defp srt_sidecars(_video_path, %{sidecars: sidecars} = cache), do: {sidecars, cache}

  # Each track is extracted once per fetch, a failure included: the own-track, embedded and
  # translation checks can all ask for the same track, and every extraction reads the whole file.
  defp extract(video_path, %{index: index}, %{extracted: extracted} = cache) do
    case Map.fetch(extracted, index) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result = extract_track(video_path, index)
        {result, %{cache | extracted: Map.put(extracted, index, result)}}
    end
  end

  defp extract_track(video_path, index) do
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

  # A sidecar's content once it passed the timing check that downloads and tracks pass (#1109).
  # Nothing is stored for a sidecar: it is a small read, checked again on each sweep, and the
  # operator can fix or replace it.
  defp timed_sidecar(path) do
    with {:ok, content} <- read(path) do
      case Timing.validate(content, ".srt") do
        :ok ->
          {:ok, content}

        {:error, reason} ->
          Logger.info("subtitle sidecar #{path} failed the timing check: #{inspect(reason)}")
          :error
      end
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
            commit_translation(video_path, kind, language, moviehash, target, rendered)

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

  # The source passed the timing check, but the translator's output can still fail it, as a cue
  # it returns empty does. That comes from the translator, not from the source track or sidecar,
  # so nothing is stored (#1109).
  defp commit_translation(video_path, kind, language, moviehash, target, rendered) do
    case Timing.validate(rendered, ".srt") do
      :ok ->
        commit(video_path, kind, language, moviehash, "translated", target, rendered)

      {:error, reason} ->
        Logger.warning(
          "subtitle translation for #{video_path} (#{language}) failed the timing check: " <>
            inspect(reason)
        )
    end
  end

  # `opts`: `enqueue:` (`:fresh`, the default, or `:background`) and `source_track:`, the embedded
  # track the content came from.
  defp commit(video_path, kind, language, moviehash, origin, target, content, opts \\ []) do
    sidecar = %{video_path: video_path, sidecar_path: target, language: language}

    case SidecarTransaction.replace(sidecar, content, origin, moviehash, opts[:source_track]) do
      :ok ->
        after_commit(video_path, kind, language, origin, Keyword.get(opts, :enqueue, :fresh))

      {:error, {:manifest, error}} ->
        Logger.warning(
          "subtitle provenance write failed for #{video_path} (#{language}): #{inspect(error)}"
        )

      {:error, {:write, error}} ->
        Logger.warning("subtitle write failed for #{video_path} (#{language}): #{inspect(error)}")
    end
  end

  defp after_commit(video_path, kind, language, origin, enqueue) do
    cond do
      origin in ["opensubtitles_hash", "opensubtitles_id"] or
          (origin == "own_track" and enqueue == :fresh) ->
        Worker.enqueue_after_download(video_path, kind)

      origin == "own_track" ->
        Worker.enqueue_in_background(video_path, kind)

      true ->
        :ok
    end

    Cinder.Library.refresh(kind, video_path)
    Logger.info("wrote #{language} subtitle for #{video_path}")
  end

  defp normalize_sidecar_mode(target) do
    case safe_destination(target) do
      {:ok, target} ->
        # Mode only, so a hardlinked download keeps seeding; the media server needs 0644 (#860).
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

  First it marks a recorded language's canonical sidecar as a release sidecar only when the
  import placed that exact file or the manifest already tracks the language. A subtitle the user
  put next to the video gets no manifest entry, so no fetch overwrites it (#918).
  """
  @spec fetch_now((-> map()), String.t(), :movies | :tv, release_sidecars()) ::
          :ok | :quota_exceeded
  def fetch_now(criteria_fun, video_path, kind, release_sidecars) do
    release_sidecars = release_sidecars!(release_sidecars)

    mark_canonical_sidecars(
      video_path,
      release_sidecars[:languages],
      {:placed, release_sidecars[:placed]}
    )

    # An import: a track found in the new file is timed like a fresh download (`own_track/7`).
    fetch_missing(Map.put(criteria_fun.(), :fresh, true), video_path, kind)
  rescue
    error -> Logger.warning("subtitle fetch crashed for #{video_path}: #{inspect(error)}")
  catch
    caught, value ->
      Logger.warning("subtitle fetch #{caught} for #{video_path}: #{inspect(value)}")
  end

  @doc """
  Marks each of `languages`' existing canonical sidecars for `video_path` as Cinder-managed in
  the manifest (origin `"release_sidecar"`), recomputing the moviehash fresh from the file. For
  `Cinder.Library.Backfill`. By default it marks only a language the manifest already tracks, as
  an import's `fetch_now/4` does, so a subtitle the user put next to the video in an untracked
  language stays theirs (#993).

  `register_untracked: true` marks an untracked language's sidecar too: the repair for a row whose
  sidecars were never registered (issue #128). Nothing on disk tells a sidecar a release shipped
  from one the user placed, so a hand-placed subtitle can then become managed, and the next fetch
  for a wanted language may replace it.

  Either way a language whose manifest cannot be read (`Manifest.load/1`) stays unmarked, with a
  warning.
  """
  @spec mark_release_sidecars(String.t(), [String.t()] | nil, register_untracked: boolean()) ::
          :ok
  def mark_release_sidecars(video_path, languages, opts \\ []) do
    markable =
      if Keyword.validate!(opts, register_untracked: false)[:register_untracked],
        do: :any,
        else: :tracked

    mark_canonical_sidecars(video_path, languages, markable)
  end

  defp mark_canonical_sidecars(_video_path, languages, _markable) when languages in [nil, []],
    do: :ok

  defp mark_canonical_sidecars(video_path, languages, markable) do
    moviehash = current_moviehash(video_path)

    Enum.each(Enum.uniq(languages), &mark_release_sidecar(video_path, moviehash, &1, markable))

    :ok
  end

  defp mark_release_sidecar(video_path, moviehash, language, markable) do
    :global.trans(lock_id(video_path), fn ->
      target = sidecar_path(video_path, language)
      put_release_sidecar(video_path, moviehash, language, target, markable)
    end)
  end

  # A manifest that cannot be read would hide the verified track or the cleanup journal the
  # marking must keep, so the language is left unmarked (#1202).
  defp put_release_sidecar(video_path, moviehash, language, target, markable) do
    case Manifest.load(video_path) do
      {:ok, state} ->
        put_release_sidecar(video_path, moviehash, language, target, markable, state)

      {:error, reason} ->
        Logger.warning("subtitle release sidecar left unmarked for #{target}: #{inspect(reason)}")
    end
  end

  defp put_release_sidecar(video_path, moviehash, language, target, markable, state) do
    if sidecar_exists?(target) and markable?(markable, state, language, target) and
         not keep_registered?(state, moviehash, language, target) do
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

  # Which existing canonical sidecars a marking may take over, with the manifest read inside the
  # video's lock. Backfill takes a language the manifest already tracks (`:tracked`), or any with
  # the operator's opt-in (`:any`). An import takes one it placed, or a tracked language.
  defp markable?(:any, _state, _language, _target), do: true
  defp markable?(:tracked, state, language, _target), do: Manifest.managed?(state, language)

  defp markable?({:placed, placed}, state, language, target),
    do: target in placed or Manifest.managed?(state, language)

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
      when origin in ["opensubtitles_hash", "opensubtitles_id", "own_track"] and
             is_binary(managed_sha256) ->
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

  @doc """
  Hands `video_path`'s managed sidecar in `language` back to the user: drops the language's
  release-sidecar entry from the manifest, under the video's lock, so no fetch writes to that file
  while it is there (#994), until a media-info backfill run with its opt-in marks it again
  (`Cinder.Library.Backfill.run/1`, `register_untracked: true`). An import before #918 could mark
  a subtitle the user put next to the video as a release sidecar, and so can that opt-in. An
  operator runs it over `bin/cinder rpc` (`docs/operating.md`, "Subtitles").
  `language` is the code in the sidecar's name (`<video>.<language>.srt`), as the manifest
  records it.

  Returns `:ok`, or `Cinder.Subtitles.Manifest.delete_track/3`'s error. Its three refusals write
  nothing: `{:error, :unknown_track}` for a language the manifest does not track,
  `{:error, {:origin, _}}` for a sidecar Cinder wrote itself, and
  `{:error, {:transaction_records, _}}` for one whose entry still holds a record of its
  replacement transaction. A failed write's error can come after the entry is gone.
  """
  @spec hand_back(String.t(), String.t()) :: :ok | {:error, term()}
  def hand_back(video_path, language) do
    :global.trans(lock_id(video_path), fn ->
      Manifest.delete_track(video_path, language, "release_sidecar")
    end)
  end

  defp current_moviehash(video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, moviehash} -> moviehash
      _ -> nil
    end
  end

  defp lock_id(video_path), do: {{__MODULE__, video_path}, self()}

  defp local_cache do
    %{
      tracks: :unknown,
      extracted: %{},
      timing_rejected: MapSet.new(),
      default_srt: :unknown,
      sidecars: :unknown,
      sidecar_srt: %{}
    }
  end

  defp provider, do: Application.fetch_env!(:cinder, :subtitles_provider)
  defp translator, do: Application.fetch_env!(:cinder, :subtitles_translator)
  defp media_info, do: Application.get_env(:cinder, :media_info)

  defp provider_config,
    do: Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
end
