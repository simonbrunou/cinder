defmodule Cinder.Library.AudioProbe do
  @moduledoc """
  Probes one audio file's container/duration/chapter/tag facts for audiobook import.

  The `Cinder.Library.MediaInfo` sibling, and a NEW behaviour rather than a widened `MediaInfo`
  (B7b plan judgment #8): `MediaInfo` is shaped around one question — a movie/TV file's
  audio/subtitle *language* tracks — and its production probes share `run_probe/2`, which has no
  execution timeout at all (only `health/0`'s `-version` call is `Task`-bounded). Reusing it here
  would mean either widening its callback shapes with audiobook-only fields no video caller ever
  reads, or bolting a third probe shape onto a behaviour whose whole moduledoc is framed around
  language policy — the same "forced reuse" smell B4c's own §4 already named. A new, narrowly
  scoped behaviour instead.

  Reached only through this behaviour, resolved from `config :cinder, :audio_probe` at runtime via
  `Application.fetch_env!/2` (never `compile_env!` — the Mox mock is defined at runtime, so
  compile-time resolution breaks `--warnings-as-errors`, per AGENTS.md). `nil` in
  `config/test.exs` by default, matching `MediaInfo`'s own test posture exactly — the existing
  import suite never shells out; `Cinder.Library.AudiobookSourcesTest` opts in per test with a Mox
  mock.

  ## Degradation, not failure

  `Cinder.Library.AudiobookSources.resolve/1` treats a `nil` probe module, a probe timeout, or a
  probe error identically: "can't verify the stronger (tag) signal", never "can't import". Track
  ordering and mixed-book detection fall back to filename-only evidence, and
  `duration_seconds`/`chapter_count`/`track_number`/`disc_number` simply stay `nil` on the
  imported `book_files` row(s). It never fails the whole import and never blocks a poller tick —
  see `Cinder.Library.AudioProbe.Ffprobe`'s own bounded-timeout implementation.
  """

  @type probe_result :: %{
          container: :m4b | :mp3 | :unknown,
          duration_seconds: non_neg_integer() | nil,
          chapter_count: non_neg_integer() | nil,
          track_tag: non_neg_integer() | nil,
          disc_tag: non_neg_integer() | nil,
          album_tag: String.t() | nil,
          title_tag: String.t() | nil
        }

  @doc "Probes `path`'s container metadata. `{:error, _}` is always a degrade, never a hard stop."
  @callback probe(path :: String.t()) :: {:ok, probe_result()} | {:error, term()}

  @doc "Reachability check, mirroring `Cinder.Library.MediaInfo.health/0`."
  @callback health() :: :ok | {:error, term()}
end
