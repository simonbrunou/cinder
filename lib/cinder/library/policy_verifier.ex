defmodule Cinder.Library.PolicyVerifier do
  @moduledoc """
  Verifies a downloaded release against its actual files before import: frozen Anime audio and
  embedded-subtitle requirements (`verify_sources/3`), and a movie's length against its TMDB
  runtime (`verify_runtime/3`).

  The verifier is pure apart from the injected MediaInfo probe and a warning on a runtime
  rejection. It does not know about catalog records, staging, or filesystem operations.
  """

  require Logger

  alias Cinder.Acquisition.Language

  @type reports :: %{String.t() => Cinder.Library.MediaInfo.probe_report()}

  @spec verify_sources([String.t()], map() | nil, module() | nil) ::
          {:ok, reports()} | {:mismatch, map()} | {:unavailable, term()}
  def verify_sources(paths, snapshot, media_info) do
    paths = Enum.uniq(paths)

    if hard_requirements?(snapshot) do
      verify_all(paths, snapshot, media_info)
    else
      {:ok, %{}}
    end
  end

  @doc """
  `verify_sources/3` as a stage error: a mismatch the poller rejects (blocklist, re-search), or an
  unavailable verdict it retries and then holds as "needs verification".
  """
  @spec verify_release([String.t()], map() | nil, module() | nil) ::
          {:ok, reports()}
          | {:error, {:release_policy_mismatch, map()} | {:release_policy_unavailable, term()}}
  def verify_release(paths, snapshot, media_info) do
    case verify_sources(paths, snapshot, media_info) do
      {:ok, reports} -> {:ok, reports}
      {:mismatch, evidence} -> {:error, {:release_policy_mismatch, evidence}}
      {:unavailable, reason} -> {:error, {:release_policy_unavailable, reason}}
    end
  end

  # A release can spell the right title and hold another film, which no name check can see. A
  # file's length is harder to fake. Only a clearly SHORTER file counts: extended and director's
  # cuts run long legitimately, and PAL speed-up trims ~4%.
  @short_runtime_ratio 0.85
  @short_runtime_minutes 10

  @doc """
  Rejects movie `sources` (`Cinder.Library.MovieSources` `{path, part}` pairs, judged together, so
  a CD1/CD2 stack counts as one film) whose probed length is at least 15% and 10 minutes short of
  `tmdb_minutes`. Returns `stage_movie`'s own `{:error, {:release_policy_mismatch, evidence}}`, so
  the poller rejects it as it does a policy mismatch: blocklisted, its download removed, the movie
  searched again (an upgrade keeps the live file). An unknown runtime, no media_info, a probe error,
  or a report without a duration all return `:ok`: only a confirmed mismatch rejects.
  """
  @spec verify_runtime(integer() | nil, [{String.t(), term()}], module() | nil) ::
          :ok | {:error, {:release_policy_mismatch, map()}}
  def verify_runtime(tmdb_minutes, [{first, _part} | _] = sources, media_info)
      when is_integer(tmdb_minutes) and tmdb_minutes > 0 and not is_nil(media_info) do
    with seconds when is_number(seconds) <- total_duration(sources, media_info),
         file_minutes = round(seconds / 60),
         true <- too_short?(seconds / 60, tmdb_minutes) do
      Logger.warning(
        "#{source_id(first)} runs #{file_minutes} min, TMDB says #{tmdb_minutes}; " <>
          "rejecting it as another film"
      )

      {:error,
       {:release_policy_mismatch,
        %{
          source: source_id(first),
          tmdb_runtime_minutes: tmdb_minutes,
          file_runtime_minutes: file_minutes
        }}}
    else
      _unverified_or_plausible -> :ok
    end
  end

  def verify_runtime(_tmdb_minutes, _sources, _media_info), do: :ok

  defp total_duration(sources, media_info) do
    Enum.reduce_while(sources, 0.0, fn {source, _part}, total ->
      case media_info.probe(source) do
        {:ok, %{duration: seconds}} when is_number(seconds) and seconds > 0 ->
          {:cont, total + seconds}

        _unknown ->
          {:halt, nil}
      end
    end)
  end

  defp too_short?(file_minutes, tmdb_minutes),
    do:
      tmdb_minutes - file_minutes >= @short_runtime_minutes and
        file_minutes <= tmdb_minutes * @short_runtime_ratio

  defp hard_requirements?(%{
         "required_audio_languages" => audio,
         "required_embedded_subtitle_languages" => subtitles
       }),
       do: audio != [] or subtitles != []

  defp hard_requirements?(_snapshot), do: false

  defp verify_all(_paths, _snapshot, nil), do: {:unavailable, :media_info_not_configured}

  defp verify_all(paths, snapshot, media_info) do
    Enum.reduce_while(paths, {:ok, %{}}, fn source, {:ok, reports} ->
      case verify_source(source, snapshot, media_info) do
        {:ok, report} -> {:cont, {:ok, Map.put(reports, source, report)}}
        {:mismatch, _evidence} = mismatch -> {:halt, mismatch}
        {:unavailable, _reason} = unavailable -> {:halt, unavailable}
      end
    end)
  end

  defp verify_source(source, snapshot, media_info) do
    case media_info.probe_policy(source) do
      {:ok, report} ->
        classify_result(classify(source, report, snapshot), report)

      {:error, reason} ->
        {:unavailable, {:probe_failed, source_id(source), safe_probe_reason(reason)}}
    end
  end

  defp safe_probe_reason(reason) when is_atom(reason), do: reason

  defp safe_probe_reason({:ffprobe_exit, code, _stderr}) when is_integer(code),
    do: {:ffprobe_exit, code}

  defp safe_probe_reason(_reason), do: :probe_error

  defp classify_result(:ok, report), do: {:ok, report}
  defp classify_result({:mismatch, _evidence} = mismatch, _report), do: mismatch
  defp classify_result({:unavailable, _reason} = unavailable, _report), do: unavailable

  defp classify(
         source,
         %{
           audio: audio,
           subtitles: subtitles,
           audio_unknown?: audio_unknown?,
           subtitle_unknown?: subtitle_unknown?
         },
         %{
           "required_audio_languages" => required_audio,
           "required_embedded_subtitle_languages" => required_subtitles
         }
       ) do
    audio_statuses =
      Enum.map(required_audio, &{&1, Language.stream_status(&1, audio, audio_unknown?)})

    subtitle_status = subtitle_status(required_subtitles, subtitles, subtitle_unknown?)
    evidence = mismatch_evidence(source, audio_statuses, required_subtitles, subtitle_status)

    cond do
      map_size(evidence) > 1 ->
        {:mismatch, evidence}

      Enum.any?(audio_statuses, fn {_language, status} -> status == :unknown end) ->
        {:unavailable, {:unprobeable_audio, source_id(source)}}

      subtitle_status == :unknown ->
        {:unavailable, {:unprobeable_subtitles, source_id(source)}}

      true ->
        :ok
    end
  end

  defp subtitle_status([], _present, _unknown?), do: :satisfied

  defp subtitle_status(required, present, unknown?) do
    statuses = Enum.map(required, &Language.stream_status(&1, present, unknown?))

    cond do
      :satisfied in statuses -> :satisfied
      :unknown in statuses -> :unknown
      true -> :mismatch
    end
  end

  defp mismatch_evidence(source, audio_statuses, required_subtitles, subtitle_status) do
    missing_audio =
      for {language, :mismatch} <- audio_statuses,
          do: language

    %{source: source_id(source)}
    |> maybe_put(:missing_audio, missing_audio)
    |> maybe_put(
      :missing_embedded_subtitles,
      if(subtitle_status == :mismatch, do: required_subtitles, else: [])
    )
  end

  defp maybe_put(evidence, _key, []), do: evidence
  defp maybe_put(evidence, key, values), do: Map.put(evidence, key, values)

  defp source_id(source), do: Path.basename(source)
end
