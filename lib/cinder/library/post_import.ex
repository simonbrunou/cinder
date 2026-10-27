defmodule Cinder.Library.PostImport do
  @moduledoc """
  What happens once a file has actually landed in the library: tell the media server to scan, and
  fetch subtitles for it.

  Carved out of `Cinder.Library` as plain code motion — every clause below is byte-for-byte what
  it was before the split, `Library.scan/1` and `Library.refresh/2` still delegate here, and the
  best-effort framing is unchanged. That framing is the point of the module: a correctly-imported
  file must never be dragged back to `:import_failed` by a media server that is down or a
  subtitle provider that hangs, so every entry point swallows and logs rather than propagating.
  """
  require Logger

  @doc "Requests a library scan and returns the configured media server's result."
  @spec scan(:movies | :tv) :: :ok | {:error, term()}
  def scan(kind), do: media_server().scan(kind)

  # A failed scan — an {:error, _} return OR a raise/exit from a misconfigured impl (e.g. a bad URL
  # deep in the HTTP stack) — must not strand a correctly-imported movie at :import_failed. The
  # media server picks it up on its next periodic scan. Log and report the import as done.
  @doc false
  @spec refresh(:movies | :tv, String.t()) :: :ok
  def refresh(kind, dest) do
    case scan(kind) do
      {:error, reason} -> log_scan_failure(dest, reason)
      _ -> :ok
    end
  rescue
    e -> log_scan_failure(dest, e)
  catch
    caught, value -> log_scan_failure(dest, {caught, value})
  end

  defp log_scan_failure(dest, reason) do
    Logger.warning("media-server scan failed after importing #{dest}: #{inspect(reason)}")
  end

  # Dispatches the subtitle fetch on a supervised Task (fetch_after_import/4) so a slow OpenSubtitles
  # round-trip can't stall the import poller tick; the fetch's own errors are handled inside the task.
  # The dispatch is still wrapped best-effort — exactly like scan/2 — so even a supervisor hiccup
  # can't turn a correctly-placed file into :import_failed. `criteria_fun` is a thunk so it's built
  # inside the isolated task, not in the caller's argument.
  @doc false
  def fetch_subtitles(criteria_fun, dest, kind, release_sidecars)
      when is_function(criteria_fun, 0) do
    Cinder.Subtitles.fetch_after_import(criteria_fun, dest, kind, release_sidecars)
  rescue
    e -> Logger.warning("subtitle fetch dispatch failed after importing #{dest}: #{inspect(e)}")
  catch
    kind, value ->
      Logger.warning(
        "subtitle fetch dispatch failed after importing #{dest}: #{inspect({kind, value})}"
      )
  end

  # One fetch per physical file: a combined-episode file (S01E01-E02) is the dest of every episode
  # it covers, and concurrent fetches would race/overwrite the shared sidecar (issue #141) — the
  # lowest-numbered covered episode names the provider query.
  @doc false
  def fetch_episode_subtitles([_ | _] = episodes, dest, release_sidecars) do
    episode = Enum.min_by(episodes, &{&1.season.season_number, &1.episode_number})

    fetch_subtitles(
      fn -> Cinder.Subtitles.episode_criteria(episode) end,
      dest,
      :tv,
      release_sidecars
    )
  end

  defp media_server, do: Application.fetch_env!(:cinder, :media_server)
end
