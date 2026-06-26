defmodule Cinder.Library.MediaInfo do
  @moduledoc """
  Probes a downloaded media file's audio-track languages — the import-time safety net behind the
  name-based language filter (`Cinder.Acquisition.Language`). A release name can mislabel or omit
  the audio language; the file's actual audio streams can't.

  Reached only through this behaviour, resolved from `config :cinder, :media_info` at runtime. It
  is **optional**: when the key is unset the importer skips the check (so an instance without
  `ffprobe` installed imports exactly as before). `config/test.exs` leaves it unset; tests that
  exercise the check set a Mox mock per-test.
  """

  @doc """
  Returns the language codes of `path`'s audio streams (lowercased; untagged/`und` streams
  dropped), or `{:error, reason}` if the probe can't run. The importer treats both an empty list
  and an error as "can't verify" and imports anyway — the check only parks on a *positive*
  mismatch, never on missing data.
  """
  @callback audio_languages(path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
end
