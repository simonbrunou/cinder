defmodule Cinder.Subtitles.Sync.ReplacementCleanup do
  @moduledoc false

  alias Cinder.Subtitles.{Manifest, Sync}
  alias Cinder.Subtitles.Sync.AtomicFile

  @spec reconcile_reversal(map()) :: :ok | {:error, term()}
  def reconcile_reversal(%{
        sidecar_path: sidecar_path,
        sync: %{status: "applying", applied_sha256: expected, expected_sha256: content}
      })
      when expected != content,
      do: AtomicFile.cleanup_reversal(sidecar_path, expected, content)

  def reconcile_reversal(%{
        sidecar_path: sidecar_path,
        sync: %{applied_sha256: expected, source_sha256: content}
      })
      when expected != content,
      do: AtomicFile.cleanup_reversal(sidecar_path, expected, content)

  def reconcile_reversal(_item), do: :ok

  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(video_path) do
    video_path
    |> Manifest.read()
    |> Map.fetch!(:tracks)
    |> Enum.reduce_while(:ok, &reconcile_track(&1, &2, video_path))
  end

  defp reconcile_track(
         {_language, %{replacement_cleanup_sync_invalid?: true}},
         :ok,
         _video_path
       ),
       do: {:halt, {:error, :invalid_replacement_cleanup_journal}}

  defp reconcile_track(
         {language, %{file: file, replacement_cleanup_sync: sync}},
         :ok,
         video_path
       ) do
    sidecar_path = Path.join(Path.dirname(video_path), file)

    with :ok <- Sync.discard_replacement(video_path, language, sidecar_path, sync),
         :ok <- Manifest.clear_replacement_cleanup(video_path, language) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, {:replacement_cleanup_failed, reason}}}
    end
  end

  defp reconcile_track({_language, _track}, :ok, _video_path), do: {:cont, :ok}
end
