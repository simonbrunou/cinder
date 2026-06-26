defmodule Cinder.Library.MediaInfo do
  @moduledoc """
  Probes a downloaded media file's audio-track languages — the import-time safety net behind the
  name-based language filter (`Cinder.Acquisition.Language`). A release name can mislabel or omit
  the audio language; the file's actual audio streams can't.

  Reached only through this behaviour, resolved from `config :cinder, :media_info` at runtime.
  Enabled by default in prod (`config/config.exs` → `Ffprobe`; the Docker image ships `ffmpeg`), and
  it degrades safely: if `ffprobe` isn't on `PATH` the probe errors and the importer imports anyway,
  and the check parks only a *confirmed* mismatch (`Cinder.Acquisition.Language.audio_satisfies?/2`
  is conservative — an unknown language or unrecognised audio code never parks). Set
  `config :cinder, media_info: nil` to disable it entirely. `config/test.exs` disables it; the
  media_info tests opt in with a Mox mock per-test.
  """

  @doc """
  Returns the language codes of `path`'s audio streams (lowercased; untagged/`und` streams
  dropped), or `{:error, reason}` if the probe can't run. The importer treats both an empty list
  and an error as "can't verify" and imports anyway — the check only parks on a *positive*
  mismatch, never on missing data.
  """
  @callback audio_languages(path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
end
