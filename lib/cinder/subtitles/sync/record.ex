defmodule Cinder.Subtitles.Sync.Record do
  @moduledoc """
  What a sync result records: the manifest's `sync` map for a sidecar, and the result row the
  worker and `/subtitle-sync` show.
  """

  alias Cinder.Subtitles.SafeFile

  @doc "The manifest `sync` map of one analysis or correction."
  @spec metadata(pos_integer(), String.t(), String.t(), String.t(), binary(), binary(), map()) ::
          map()
  def metadata(version, status, method, moviehash, source, applied, metrics) do
    %{
      version: version,
      status: status,
      method: method,
      moviehash: moviehash,
      source_sha256: SafeFile.sha256(source),
      applied_sha256: SafeFile.sha256(applied),
      offset_ms: Map.get(metrics, :offset_ms, 0),
      rate: Map.get(metrics, :rate, 1.0) * 1.0,
      score: Map.get(metrics, :score),
      reason: reason(Map.get(metrics, :reason))
    }
    |> put_piecewise(metrics)
    |> put_shot_changes(metrics)
  end

  @doc "The result row of one sidecar."
  @spec result(map(), atom(), String.t() | nil, map()) :: map()
  def result(item, status, method, metadata) do
    %{
      id: item.id,
      label: item.label,
      video_path: item.video_path,
      status: status,
      method: method,
      offset_ms: Map.get(metadata, :offset_ms, 0),
      rate: Map.get(metadata, :rate, 1.0),
      score: Map.get(metadata, :score),
      reason: Map.get(metadata, :reason)
    }
    |> put_piecewise(metadata)
  end

  # Only a piecewise alignment carries these, and only then are they worth recording: `offset_ms`
  # above is the global search that preceded the splits, so on its own it reports a 40s tail
  # correction as "0 ms". The segment count and the largest applied shift are what make the row
  # readable in `/subtitle-sync`.
  defp put_piecewise(map, %{segments: segments, max_offset_ms: max_offset_ms})
       when is_integer(segments) and segments > 1 and is_integer(max_offset_ms) do
    Map.merge(map, %{segments: segments, max_offset_ms: max_offset_ms})
  end

  defp put_piecewise(map, _metrics), do: map

  # Whether the timing rules had the video's shot changes: a result recorded without them is
  # redone once they become known.
  defp put_shot_changes(map, %{shot_changes: true}), do: Map.put(map, :shot_changes, true)
  defp put_shot_changes(map, _metrics), do: map

  defp reason(nil), do: nil
  defp reason(value) when is_atom(value), do: Atom.to_string(value)
  defp reason(value) when is_binary(value), do: value
  defp reason(value), do: inspect(value)
end
