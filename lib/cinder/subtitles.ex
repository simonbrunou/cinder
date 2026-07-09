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
    Enum.reduce_while(wanted_languages(), :ok, fn lang, _acc ->
      case fetch_one(criteria_base, lang, dest_path) do
        :quota_exceeded -> {:halt, :quota_exceeded}
        _ -> {:cont, :ok}
      end
    end)
  end

  @doc """
  Dispatches `fetch_missing/2` for a just-imported file on a supervised Task, so a slow
  OpenSubtitles round-trip can't stall the import poller tick. Returns `:ok` immediately.
  `criteria_fun` is a thunk so criteria-building (and any failure) stays inside the isolated task.
  """
  @spec fetch_after_import((-> map()), String.t()) :: :ok
  def fetch_after_import(criteria_fun, dest_path) when is_function(criteria_fun, 0) do
    Task.Supervisor.start_child(Cinder.Subtitles.TaskSupervisor, fn ->
      safe_fetch(criteria_fun, dest_path)
    end)

    :ok
  end

  # criteria_fun runs INSIDE the task (and this rescue/catch) so a preload/criteria surprise or a
  # provider blow-up crashes only the isolated task, never the import that dispatched it.
  defp safe_fetch(criteria_fun, dest_path) do
    fetch_missing(criteria_fun.(), dest_path)
  rescue
    e -> Logger.warning("subtitle fetch crashed for #{dest_path}: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("subtitle fetch #{kind} for #{dest_path}: #{inspect(value)}")
  end

  # The sidecar-existence check (fs().lstat/1) lives INSIDE this rescue/catch, not in a
  # comprehension guard — a raising Filesystem impl must not escape fetch_missing/2, same
  # guarantee as Cinder.Library.scan/2.
  defp fetch_one(criteria_base, lang, dest_path) do
    path = sidecar_path(dest_path, lang)

    if sidecar_exists?(path) do
      :ok
    else
      search_and_write(criteria_base, lang, dest_path, path)
    end
  rescue
    e -> Logger.warning("subtitle fetch crashed for #{dest_path} (#{lang}): #{inspect(e)}")
  catch
    kind, value -> Logger.warning("subtitle fetch #{kind} for #{dest_path}: #{inspect(value)}")
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

  # Best candidate: exact language, not hearing-impaired, not machine-translated, most downloads.
  defp best(results, lang) do
    results
    |> Enum.filter(fn r ->
      String.downcase(r.language || "") == lang and not r.hearing_impaired and not r.ai_translated and
        not is_nil(r.file_id)
    end)
    |> Enum.max_by(& &1.downloads, fn -> nil end)
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
