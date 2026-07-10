defmodule Cinder.Subtitles do
  @moduledoc """
  Fetches subtitle sidecars for imported files, in the household's configured languages.

  Best-effort: failures are logged, never raised, so a subtitle miss can't affect the video import.
  `fetch_missing/2` returns `:ok`, or `:quota_exceeded` to tell a batch caller (the sweep) to stop
  for this run once the daily download quota is spent. `fetch_after_import/2` runs it off-process
  (a supervised Task) so a slow provider can't stall the import poller. Idempotent: a language whose
  sidecar already exists is skipped (no search, no download, no wasted quota). The "which languages /
  which candidate" policy lives here; the network lives in `Cinder.Subtitles.Provider`.
  """

  require Logger

  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Subtitles.{Fetcher, Moviehash}

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

  @doc "The sidecar path for `dest_path` in `lang`: the video's extension replaced by `.<lang>.srt`."
  @spec sidecar_path(String.t(), String.t()) :: String.t()
  def sidecar_path(dest_path, lang) do
    dir = Path.dirname(dest_path)
    base = Path.basename(dest_path, Path.extname(dest_path))
    Path.join(dir, "#{base}.#{lang}.srt")
  end

  @doc """
  For each wanted language whose sidecar is absent, search the provider, pick the best candidate,
  download it, and write the sidecar. `criteria_base` carries `:imdb_id`/`:tmdb_id`
  (+ `:season`/`:episode` for TV); `:languages` is filled in per language. Returns `:ok`, or
  `:quota_exceeded` (the daily download cap is spent) so a batch caller — the sweep — can stop.
  """
  @spec fetch_missing(map(), String.t()) :: :ok | :quota_exceeded
  def fetch_missing(criteria_base, dest_path) do
    case wanted_languages() do
      [] -> :ok
      langs -> fetch_languages(criteria_base, langs, dest_path)
    end
  end

  # Hash computed lazily on the first language that actually needs a search, then threaded through
  # the accumulator and reused — so a title whose sidecars all exist reads no bytes, while a fetch
  # that does search still hashes only once. `nil` = not yet computed.
  defp fetch_languages(criteria_base, langs, dest_path) do
    {status, _criteria} =
      Enum.reduce_while(langs, {:ok, nil}, fn lang, {_status, criteria} ->
        case fetch_one(criteria, criteria_base, lang, dest_path) do
          {:quota_exceeded, criteria} -> {:halt, {:quota_exceeded, criteria}}
          {_status, criteria} -> {:cont, {:ok, criteria}}
        end
      end)

    status
  end

  # Best-effort: a hashable file adds :moviehash (sync-accurate matches); :too_small / error just
  # leaves the id search as-is.
  defp with_moviehash(criteria_base, dest_path) do
    case Moviehash.of_file(dest_path) do
      {:ok, hash} -> Map.put(criteria_base, :moviehash, hash)
      _ -> criteria_base
    end
  end

  @doc """
  Dispatches `fetch_missing/2` for a just-imported file, off the import poller tick so a slow
  OpenSubtitles round-trip can't stall it. Returns `:ok` immediately. The fetch is enqueued on the
  single serializing `Cinder.Subtitles.Fetcher` — one request in flight at a time — so a bulk import
  (a whole series added at once) can't burst OpenSubtitles into rate-limiting it (issue #80).
  `criteria_fun` is a thunk so criteria-building (and any failure) stays inside the isolated fetch.
  """
  @spec fetch_after_import((-> map()), String.t()) :: :ok
  def fetch_after_import(criteria_fun, dest_path) when is_function(criteria_fun, 0) do
    Fetcher.enqueue(criteria_fun, dest_path)
  end

  @doc """
  Runs one import's subtitle fetch synchronously (the body the `Fetcher` executes per queued file).
  `criteria_fun` runs INSIDE this rescue/catch so a preload/criteria surprise or a provider blow-up
  crashes nothing — it logs and the caller (the Fetcher) moves on to the next queued fetch.
  """
  @spec fetch_now((-> map()), String.t()) :: :ok | :quota_exceeded
  def fetch_now(criteria_fun, dest_path) when is_function(criteria_fun, 0) do
    fetch_missing(criteria_fun.(), dest_path)
  rescue
    e -> Logger.warning("subtitle fetch crashed for #{dest_path}: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("subtitle fetch #{kind} for #{dest_path}: #{inspect(value)}")
  end

  # The sidecar-existence check (fs().lstat/1) lives INSIDE this rescue/catch, not in a
  # comprehension guard — a raising Filesystem impl must not escape fetch_missing/2, same
  # guarantee as Cinder.Library.scan/2. `criteria` is the memoized (moviehash-merged) criteria,
  # nil until the first search; returned so the loop reuses a single hash across languages.
  # ponytail: on the rare raise-after-hash path the rescue returns the pre-hash `criteria` (Elixir
  # try scoping), so the next language recomputes — one wasted local read, accepted.
  defp fetch_one(criteria, criteria_base, lang, dest_path) do
    path = sidecar_path(dest_path, lang)

    if sidecar_exists?(path) do
      {:ok, criteria}
    else
      criteria = criteria || with_moviehash(criteria_base, dest_path)
      {search_and_write(criteria, lang, dest_path, path), criteria}
    end
  rescue
    e ->
      Logger.warning("subtitle fetch crashed for #{dest_path} (#{lang}): #{inspect(e)}")
      {:ok, criteria}
  catch
    kind, value ->
      Logger.warning("subtitle fetch #{kind} for #{dest_path}: #{inspect(value)}")
      {:ok, criteria}
  end

  defp search_and_write(criteria_base, lang, dest_path, path) do
    criteria = Map.put(criteria_base, :languages, [lang])

    with {:ok, results} <- provider().search(criteria),
         %{file_id: file_id} <- best(results, lang),
         {:ok, content} <- provider().download(file_id),
         :ok <- fs().write(path, content) do
      Logger.info("wrote #{lang} subtitle for #{dest_path}")
    else
      {:error, :quota_exceeded} ->
        Logger.info("OpenSubtitles daily download quota reached; pausing subtitle fetch this run")
        :quota_exceeded

      nil ->
        :ok

      # Provider failures (revoked key → 401/403, login failure, timeouts) must not be
      # conflated with "no subtitle exists" at :info — a broken credential would silently
      # stop subtitles while every 12h sweep "succeeds".
      {:error, reason} ->
        Logger.warning("subtitle fetch for #{dest_path} (#{lang}) failed: #{inspect(reason)}")

      other ->
        Logger.info("no #{lang} subtitle for #{dest_path}: #{inspect(other)}")
    end
  end

  # Best candidate: exact language, not hearing-impaired, not machine-translated, has a file_id.
  # Prefer a moviehash-synced match, then most downloads.
  defp best(results, lang) do
    results
    |> Enum.filter(fn r ->
      String.downcase(r.language || "") == lang and not r.hearing_impaired and not r.ai_translated and
        not is_nil(r.file_id)
    end)
    |> Enum.max_by(&{(Map.get(&1, :moviehash_match, false) && 1) || 0, &1.downloads}, fn ->
      nil
    end)
  end

  defp sidecar_exists?(path) do
    match?({:ok, _}, fs().lstat(path))
  end

  defp provider, do: Application.fetch_env!(:cinder, :subtitles_provider)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  # Languages live under the OpenSubtitles provider config (the single provider today; if a second
  # provider is ever added, promote this to a provider-agnostic flat key — see the design ceiling).
  defp provider_config,
    do: Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
end
