defmodule Cinder.Library.MediaInfo do
  @moduledoc """
  Probes a downloaded media file's audio-track languages — the import-time safety net behind the
  name-based language filter (`Cinder.Acquisition.Language`). A release name can mislabel or omit
  the audio language; the file's actual audio streams can't.

  Reached only through this behaviour, resolved from `config :cinder, :media_info` at runtime.
  Enabled by default in prod (`config/config.exs` → `Ffprobe`; the Docker image ships `ffmpeg`).
  When `ffprobe` isn't on `PATH` the two probes degrade differently: `probe/1` errors and the
  name-based audio check imports anyway, parking only a *confirmed* mismatch
  (`Cinder.Acquisition.Language.audio_satisfies?/2` is conservative — an unknown language or
  unrecognised audio code never parks); `probe_policy/1` errors reach
  `Cinder.Library.PolicyVerifier` as `{:unavailable, _}` and hold the item as "needs verification"
  when the frozen release-policy snapshot names a required audio or embedded-subtitle language.
  Set `config :cinder, media_info: nil` to disable it entirely — same split, the verifier reports
  `:media_info_not_configured` rather than skipping a hard requirement. `config/test.exs` disables
  it; the media_info tests opt in with a Mox mock per-test.
  """

  @type subtitle_track :: %{
          required(:index) => non_neg_integer(),
          # The RAW registry code as reported by the probe (e.g. "chi", "eng"), validated against
          # `Cinder.Acquisition.Language.known?/1` but deliberately NEVER canonicalized through
          # `Language.normalize/1` — normalizing away "chi"/"zho" (accepted by both "zh" and "cn")
          # into one value would make an ambiguous generic-Chinese track indistinguishable from an
          # explicitly Mandarin "cmn" one to a "cn" (Cantonese) selector (#573). Compare it with
          # `Language.raw_track_satisfies?/2` / `Language.exact_track?/2`, never `==`/`normalize/1`.
          required(:language) => String.t(),
          required(:default?) => boolean(),
          required(:forced?) => boolean(),
          optional(:packet_count) => non_neg_integer()
        }

  @type probe_report :: %{
          required(:audio) => [String.t()],
          required(:subtitles) => [String.t()],
          required(:audio_unknown?) => boolean(),
          required(:subtitle_unknown?) => boolean(),
          optional(:default_audio) => String.t() | nil
        }

  @doc """
  Probes `path`'s streams. Returns `{:ok, %{audio: [code], subtitles: [code]}}` — the language
  codes of the audio and subtitle streams (lowercased; untagged/`und` dropped) — or
  `{:error, reason}` if the probe can't run. The importer treats an error as "can't verify" and
  imports anyway; the audio park check reads `.audio` and parks only on a *positive* mismatch.

  `.default_audio` is the language of the default audio track — what a player selects absent a
  viewer preference, which `.audio` cannot express (issue #197). It is `nil` unless the
  default-flagged tracks all name one tagged language: nothing flagged, an untagged flagged track,
  and flagged tracks that *disagree* (FlagDefault means "eligible for automatic selection", so the
  player picks among them by viewer preference) all mean "not established", and callers must not
  warn on any of them.
  See `Cinder.Acquisition.Language.default_audio_mismatch?/3`.
  """
  # `default_audio` is `optional` so an existing Mox stub returning only audio/subtitles stays
  # valid; every read goes through `Map.get(report, :default_audio)`.
  @callback probe(path :: String.t()) ::
              {:ok,
               %{
                 required(:audio) => [String.t()],
                 required(:subtitles) => [String.t()],
                 optional(:default_audio) => String.t() | nil
               }}
              | {:error, term()}

  @doc "Probes streams while preserving whether audio or subtitle language tags are unknown."
  @callback probe_policy(path :: String.t()) :: {:ok, probe_report()} | {:error, term()}

  @doc """
  Lists the file's text-based subtitle streams for embedded-track selection
  (`Cinder.Subtitles.local_source/4`, `Cinder.Subtitles.Sync.Reference.select/4`). See
  `subtitle_track/0` — `:language` is a raw, un-normalized code.
  """
  @callback subtitle_tracks(path :: String.t()) ::
              {:ok, [subtitle_track()]} | {:error, term()}

  @callback extract_subtitle(path :: String.t(), index :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Reachability check for `/status` and the settings \"Test connection\" button."
  @callback health() :: :ok | {:error, term()}
end
