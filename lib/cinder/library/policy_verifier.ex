defmodule Cinder.Library.PolicyVerifier do
  @moduledoc """
  Verifies frozen Anime audio and embedded-subtitle requirements against authoritative sources.

  The verifier is pure apart from the injected MediaInfo probe. It does not know about catalog
  records, staging, or filesystem operations.
  """

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
