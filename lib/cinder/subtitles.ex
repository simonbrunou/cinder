defmodule Cinder.Subtitles do
  @moduledoc """
  Fetches subtitle sidecars for imported files, in the household's configured languages.

  Best-effort: `fetch_missing/2` always returns `:ok`; failures are logged, never raised, so a
  subtitle miss can't affect the video import. Idempotent: a language whose sidecar already exists
  is skipped (no search, no download, no wasted quota). The "which languages / which candidate"
  policy lives here; the network lives in `Cinder.Subtitles.Provider`.
  """

  require Logger

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
  (+ `:season`/`:episode` for TV); `:languages` is filled in per language. Always `:ok`.
  """
  @spec fetch_missing(map(), String.t()) :: :ok
  def fetch_missing(criteria_base, dest_path) do
    Enum.each(wanted_languages(), fn lang -> fetch_one(criteria_base, lang, dest_path) end)
    :ok
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
      nil -> :ok
      other -> Logger.info("no #{lang} subtitle for #{dest_path}: #{inspect(other)}")
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
