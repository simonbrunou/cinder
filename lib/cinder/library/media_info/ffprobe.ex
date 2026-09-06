defmodule Cinder.Library.MediaInfo.Ffprobe do
  @moduledoc """
  `Cinder.Library.MediaInfo` via the `ffprobe` CLI (FFmpeg). Reads every stream's `codec_type`,
  `default` disposition and `language` tag in one call, buckets audio vs subtitle streams, and
  drops untagged/`und` streams. `default_audio` reports the default audio track's language
  separately — `nil` unless every default-flagged track names the same language, since Matroska's
  FlagDefault means "eligible for automatic selection", not "this one plays" (issue #197).

  Returns `{:ok, %{audio: codes, subtitles: codes, default_audio: code | nil}}` or
  `{:error, reason}` when `ffprobe` is missing, exits non-zero, or is killed for exceeding its
  bound. The two probes degrade differently on that error: a `probe/1` error (or empty lists) is
  "can't verify" and the name-based audio check imports anyway, so a host without `ffprobe` never
  blocks that path; a `probe_policy/1` error becomes `{:unavailable, _}` in
  `Cinder.Library.PolicyVerifier` and holds the item as "needs verification" whenever the frozen
  release-policy snapshot names a required audio or embedded-subtitle language.

  The binary is `ffprobe` on `PATH` by default; override with `config :cinder, :ffprobe_bin`. The
  companion `ffmpeg` binary (used only by `extract_subtitle/2`) defaults to `ffmpeg` on `PATH`;
  override with `config :cinder, :ffmpeg_bin`.

  ## Bounded subprocess execution (issue #447)

  `probe/1`, `probe_policy/1`, `subtitle_tracks/1` and `extract_subtitle/2` all shell out to
  inspect an actual file's bytes, unlike `health/0`'s cheap `-version` no-file call.
  `probe/1`/`probe_policy/1` (via `Cinder.Library.capture_media/1`, `verify_audio/2`,
  `verify_release_policy/2`, `reject_wrong_audio/2`) run synchronously inside
  `Cinder.Download.Poller`/`Cinder.Download.TvPoller`'s single-process tick, and `isolate/2`'s
  bare `rescue` is not a timeout boundary — a hung `ffprobe` there used to stall every subsequent
  tick, import, and park for every movie and TV target, indefinitely.

  `subtitle_tracks/1` and `extract_subtitle/2` are reached only through `Cinder.Subtitles` —
  never from the movie/TV import poller's own tick. `Cinder.Library.PostImport.fetch_subtitles/4`
  deliberately dispatches onto `Cinder.Subtitles.Fetcher`, a dedicated serializing `GenServer`,
  *specifically* so a slow subtitle round-trip can't stall the import poller; the periodic
  `Cinder.Subtitles.Sweeper` backfill is likewise its own independent poller process. A hang
  there stalls only that worker's own queue/tick, not `Poller`/`TvPoller` — but it is still a
  real, unbounded hang (an orphaned `ffprobe`/`ffmpeg` leaking a staging-file fd forever), so it
  still needs a bound. Both are, despite appearances, full-file demux passes rather than cheap
  reads — `subtitle_tracks/1`'s `-count_packets` must read every packet of the selected stream
  to EOF, and `extract_subtitle/2` must demux the whole container to EOF to extract a complete,
  interleaved subtitle track — so both get the same much larger bound,
  `@subtitle_tracks_timeout_ms` / `@extract_timeout_ms`, instead of `probe/1`/`probe_policy/1`'s
  10s: see those two attributes' comments for the measurements and worst-case arithmetic behind
  the split. The two 10s calls are the ones that actually run inside the poller tick, which is
  where a tight bound matters; the two 30-minute calls never do.

  This module bounds all five calls — `probe/1`, `probe_policy/1`, `subtitle_tracks/1`,
  `extract_subtitle/2`, and `health/0` — with a supervised `Port` + `SIGKILL`-by-`os_pid`, the
  same idiom `Cinder.Library.BookArchive.Rar.run_extraction/6`/`list_entries/3`,
  `Cinder.Library.AudioProbe.Ffprobe.probe/1`, and `Cinder.Disk.CommandProbe` already use for
  their own subprocesses (#510: `health/0`'s own `-version` no-file call used the lighter
  `Task.async`/`Task.yield`/`Task.shutdown(:brutal_kill)` idiom until it was found to leak the
  same way). `Task.shutdown(:brutal_kill)` only kills the *Elixir* task; closing a port does not
  kill the child OS process on the other end when that child never reads stdin, which is exactly
  `ffmpeg` and `ffprobe`'s situation here (`ffmpeg` is invoked with `-nostdin`). Since both the
  poller and `Cinder.Subtitles.Fetcher`/`Sweeper` retry (every tick, or every enqueued/swept
  file), that lighter idiom would leak one orphaned `ffprobe`/`ffmpeg` per retry, each holding an
  open file descriptor on the staging file being probed — worse than the original hang. The
  heavier pattern here kills the actual OS process by pid, not merely the Elixir side of the port.

  Neither `Poller`, `TvPoller`, nor `Cinder.Subtitles.Sweeper` (all three built on the same
  `PollerSkeleton`) traps exits or has a catch-all `handle_info/2` (only `PollerSkeleton`'s
  `:poll` clause) — a stray `{port, {:data, _}}` or `{port, {:exit_status, _}}` arriving in a
  caller's mailbox *after* this module has already returned would crash it with a
  `FunctionClauseError` — the exact kind of failure this whole feature exists to prevent.
  So the deadline path does not merely kill and best-effort-wait: it closes the port (stopping any
  further messages) and then drains, with a non-blocking `after 0` receive loop, every message
  already queued for that port before returning — guaranteeing zero port messages ever reach the
  caller after the call returns, timeout or not.
  """
  @behaviour Cinder.Library.MediaInfo

  alias Cinder.Acquisition.Language

  @ignored ~w(und unknown)
  @text_codecs ~w(subrip ass ssa mov_text text webvtt)
  @stderr_env "CINDER_FFMPEG_STDERR"
  @health_timeout 3_000

  # `probe/1`/`probe_policy/1` read stream metadata only — codec_type/disposition/language tags,
  # no decoding, no packet counting — matching `Cinder.Library.AudioProbe.Ffprobe`'s own
  # `@probe_timeout 10_000` for the same class of call. `subtitle_tracks/1` looks like the same
  # class of call but is NOT: see `@subtitle_tracks_timeout_ms` below.
  @probe_timeout_ms 10_000

  # `subtitle_track_args/1` passes `-count_packets`, which ffprobe's own docs describe as
  # counting packets per stream: the demuxer must read every packet of the selected stream from
  # start to EOF, not just parse the container header, so this is NOT a cheap metadata-only read
  # despite `-select_streams s` narrowing what gets *reported*. Measured directly against
  # `subtitle_track_args/1`'s exact argument list (ffprobe 9.0.1, synthetic MKVs with one
  # embedded SRT track, page cache warm so the numbers isolate CPU/demux cost from disk I/O): the
  # same command WITHOUT `-count_packets` held flat at ~30-40ms from a 31KB/10s file up to a
  # 249MB/24h file (an 8000x size range — a pure header read), while WITH `-count_packets` grew
  # from ~31ms (4 packets) to ~84ms (28,800 packets) over that same range. The cost scales with
  # content, confirming the documented behaviour rather than assuming it. `-count_packets` cannot
  # be dropped to dodge this: `Cinder.Subtitles.Sync.Reference.resolver/2` sorts candidate tracks
  # by `packet_count` to pick the broadest-reference one, so the count is load-bearing.
  #
  # That warm-cache run only isolates CPU/demux cost — not what a 30-minute bound needs to prove,
  # I/O is. Measured again at real scale, cold cache, to close that gap: three real H.264/AAC/SRT
  # MKVs (1.02GB/4.03GB/10.05GB, ffmpeg-encoded, not the tiny synthetic files above), page cache
  # evicted per file with `posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)` (no root needed; verified
  # 0 resident pages via `fincore` before each run) so every read actually hits disk. This exact
  # `subtitle_track_args/1` command, cold: 0.31s/0.66s/1.48s across the three sizes — linear in
  # file size, user-CPU alone holding at ~0.02-0.03s/GB throughout; `ffmpeg_args/2` below showed
  # the identical linear, CPU-negligible shape (0.27s/0.68s/1.50s cold). So this bound is sized by
  # I/O THROUGHPUT, not CPU or packet count — extrapolating the measured CPU rate to 80GB adds
  # only ~2s against the ~1024s I/O term below. The one number that arithmetic still can't touch —
  # no household NAS exists to test against here — is the assumed ~80MB/s sustained throughput
  # itself: a conservative, commonly-cited real-world SMB/NFS-over-gigabit figure, not a
  # measurement, and the single input that would change this bound if it's wrong. Real deployment
  # telemetry (this household's actual largest file, its actual sustained transfer rate) is what
  # should recalibrate it, not a lab run against synthetic content on local disk.
  #
  # Unlike `probe/1`/`probe_policy/1`, `subtitle_tracks/1` never runs inside
  # `Poller`/`TvPoller`'s tick (see the moduledoc) — only inside `Cinder.Subtitles.Fetcher`'s own
  # serialized queue or `Cinder.Subtitles.Sweeper`'s own independent tick — so a generous bound
  # here only delays the next queued subtitle fetch or the rest of one sweep pass, never an
  # import/grab/park cycle. Nothing can turn that delay into a crash: `Fetcher` defines no
  # `handle_call` (nothing ever blocks waiting on it), and `Cinder.Subtitles.Sync.Worker` never
  # blocks on the probe either — `start_next/1` spawns it `Task.Supervisor.async_nolink` and
  # returns immediately, and every `handle_call` the Worker answers (e.g. `managed_video_paths/1`)
  # replies straight from `state`, never from the in-flight task — so no LiveView or HTTP request
  # can hang or crash behind a long probe. Worst realistic case for this deployment: a 60-80GB 4K
  # UHD remux (Cinder's own target deployment serves media over a household NAS) read over a
  # gigabit link — at the assumed ~80MB/s above, ~1024s (~17 minutes) of I/O plus ~2s of CPU. 30
  # minutes leaves comfortable headroom over that projected worst case while still turning a
  # genuinely hung/corrupt probe into a finite failure instead of parking `Fetcher`'s queue (or
  # one `Sweeper` pass) forever. The asymmetry favors staying generous: a bound below a legitimate
  # scan gets the call killed and `Reference.resolver/2` silently falls back to `&audio/1`
  # (reference.ex:11) — degraded sync quality with no visible error — while a bound above one only
  # delays background work by the time that work would legitimately have taken anyway.
  #
  # `extract_subtitle/2` shares this exact bound and reasoning, not `probe/1`/`probe_policy/1`'s
  # 10s: `ffmpeg_args/2` (`-i <path> -map 0:<index> -c:s srt -f srt pipe:1`) has to demux the
  # whole input from start to EOF to extract a COMPLETE subtitle track, for the same reason
  # `-count_packets` does — a subtitle stream's packets are interleaved with every other stream's
  # throughout the container, not stored contiguously. The cold-cache measurement above (0.27s/
  # 0.68s/1.50s across 1.02GB/4.03GB/10.05GB) shows the identical linear, I/O-dominated shape, so
  # it gets the identical 30-minute bound. One property worth recording, not changing here:
  # `Cinder.Subtitles.Sync.Reference.select/4` calls this inside `Enum.find_value/3`
  # (reference.ex:22-27), trying each same-language non-forced candidate track until one succeeds
  # — every attempt is its own full-file demux, so a file with several candidate tracks
  # legitimately costs several full passes per sync unit, not only on a timeout. The per-call
  # bound compounds across tracks; that's inherent to the caller's retry loop, orthogonal to this
  # bound's value.
  @subtitle_tracks_timeout_ms 1_800_000
  @extract_timeout_ms 1_800_000

  # Bounded wait for a killed process to actually exit before giving up on it and closing the
  # port out from under it regardless — mirrors `BookArchive.Rar`'s `@reap_wait_ms` /
  # `Cinder.Disk.CommandProbe`'s `@reap_wait`.
  @reap_wait_ms 200

  @impl true
  def probe(path), do: run_probe(path, &parse/1)

  @impl true
  def probe_policy(path), do: run_probe(path, &parse_policy/1)

  # `-version` is a cheap no-file call, but that does not make a hung binary harmless (#510): it
  # must still not stall /status or "Test connection" indefinitely, and a killed Elixir task must
  # not leave the OS process behind. Bounded the same supervised Port + SIGKILL way as the other
  # four, file-inspecting calls below — see the moduledoc's "Bounded subprocess execution"
  # section. `run_bounded/4` already returns the exact `{:error, %ErlangError{original: :enoent}}`
  # shape a missing binary needs, so no separate rescue is required here.
  @impl true
  def health do
    case run_bounded(bin(), ["-version"], health_timeout_ms(), stderr_to_stdout: true) do
      {:ok, _out, 0} -> :ok
      {:ok, out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      {:error, _reason} = error -> error
    end
  end

  defp run_probe(path, parser) do
    case run_bounded(bin(), args(path), probe_timeout_ms(), stderr_to_stdout: true) do
      {:ok, out, 0} -> {:ok, parser.(out)}
      {:ok, out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      {:error, _reason} = error -> error
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def subtitle_tracks(path) do
    case run_bounded(bin(), subtitle_track_args(path), subtitle_tracks_timeout_ms(),
           stderr_to_stdout: true
         ) do
      {:ok, out, 0} ->
        with {:ok, metadata} <- Jason.decode(out) do
          {:ok, parse_subtitle_tracks(metadata)}
        end

      {:ok, out, code} ->
        {:error, {:ffprobe_exit, code, String.trim(out)}}

      {:error, _reason} = error ->
        error
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def extract_subtitle(path, index) do
    stderr_path =
      Path.join(System.tmp_dir!(), "cinder-ffmpeg-#{System.unique_integer([:positive])}.stderr")

    ffmpeg = ffmpeg_executable!()

    try do
      case run_bounded(
             "/bin/sh",
             [
               "-c",
               "exec \"$@\" 2> \"$#{@stderr_env}\"",
               "--",
               ffmpeg | ffmpeg_args(path, index)
             ],
             extract_timeout_ms(),
             env: [{@stderr_env, stderr_path}]
           ) do
        {:ok, out, 0} -> {:ok, out}
        {:ok, _out, code} -> {:error, {:ffmpeg_exit, code, read_stderr(stderr_path)}}
        {:error, _reason} = error -> error
      end
    after
      File.rm(stderr_path)
    end
  rescue
    e -> {:error, e}
  end

  # One line per stream: "codec_type,default,language" — `default` is the disposition flag (1/0),
  # `language` empty (or the field absent) when the stream has no tag.
  defp args(path),
    do: ~w(-v error
        -show_entries stream=codec_type:stream_disposition=default:stream_tags=language
        -of csv=p=0) ++ [path]

  @doc false
  def parse(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", _default?, lang} <- rows, lang != nil, do: lang)),
      subtitles: Enum.uniq(for({"subtitle", _default?, lang} <- rows, lang != nil, do: lang)),
      default_audio: default_audio(rows)
    }
  end

  @doc false
  def parse_policy(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", _default?, lang} <- rows, is_binary(lang), do: lang)),
      subtitles: Enum.uniq(for({"subtitle", _default?, lang} <- rows, is_binary(lang), do: lang)),
      audio_unknown?: Enum.any?(rows, &match?({"audio", _default?, nil}, &1)),
      subtitle_unknown?: Enum.any?(rows, &match?({"subtitle", _default?, nil}, &1)),
      default_audio: default_audio(rows)
    }
  end

  # The language of the default audio track: what a player selects absent a viewer preference, and
  # the one fact `:audio` cannot express — a MULTi release with the dub flagged default is, as a set
  # of languages, identical to one with the original flagged default (issue #197).
  #
  # Established ONLY when the default-flagged audio tracks all name one language. Everything else is
  # nil, and the caller must not warn on nil:
  #
  #   * nothing flagged — no evidence at all;
  #   * the lone flagged track untagged — it may well BE the wanted language, so naming any other
  #     track as what plays would state the opposite of the fact;
  #   * several flagged tracks DISAGREEING — Matroska's FlagDefault marks a track "eligible for
  #     automatic selection", not "this one plays" (RFC 9559 §5.1.4.1.5; §19.1's own example flags
  #     three audio tracks). The player chooses among the eligible ones by the viewer's language
  #     preference, so a file flagging both fre and eng is correct and must not be warned about,
  #     and stream order is no proxy for that choice.
  #
  # Enum.uniq is what makes that last rule about *languages* rather than track count: the common
  # MULTi shape of one dub in 5.1 plus the same dub in 2.0, both flagged, is unambiguous — every
  # eligible track is French — and is exactly issue #197's failure mode, so it must still warn.
  #
  # Kept out of `:audio` deliberately — an `und` entry there would trip
  # `Language.audio_satisfies?/2`'s unrecognised-code escape and silently disable wrong-language
  # parks for the whole file.
  defp default_audio(rows) do
    case Enum.uniq(for {"audio", true, lang} <- rows, do: lang) do
      [lang] -> lang
      _none_or_disagreeing -> nil
    end
  end

  @doc false
  def parse_subtitle_tracks(%{"streams" => streams}) when is_list(streams) do
    for %{"index" => index, "codec_name" => codec_name} = stream <- streams,
        is_integer(index) and index >= 0,
        codec_name in @text_codecs do
      %{
        index: index,
        language: subtitle_language(stream),
        default?: disposition?(stream, "default"),
        forced?: disposition?(stream, "forced"),
        packet_count: packet_count(stream)
      }
    end
  end

  def parse_subtitle_tracks(_), do: []

  # "audio,1,eng" -> {"audio", true, "eng"}; "video,0" / "audio,0,und" -> {_, _, nil}
  # (dropped downstream).
  defp parse_rows(out) do
    out
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    case String.split(line, ",", parts: 3) do
      [type, default, lang] -> {String.trim(type), default?(default), normalize(lang)}
      [type, default] -> {String.trim(type), default?(default), nil}
      [type] -> {String.trim(type), false, nil}
    end
  end

  defp default?(flag), do: String.trim(flag) == "1"

  defp normalize(lang) do
    code = lang |> String.trim() |> String.downcase()
    if code == "" or code in @ignored, do: nil, else: code
  end

  defp subtitle_track_args(path) do
    ~w(-v error -count_packets -select_streams s
      -show_entries stream=index,codec_name,nb_read_packets:stream_disposition=default,forced:stream_tags=language
      -of json) ++ [path]
  end

  defp packet_count(%{"nb_read_packets" => count}) when is_binary(count) do
    case Integer.parse(count) do
      {value, ""} when value >= 0 -> value
      _ -> 0
    end
  end

  defp packet_count(_stream), do: 0

  defp ffmpeg_args(path, index) do
    [
      "-nostdin",
      "-v",
      "error",
      "-i",
      path,
      "-map",
      "0:#{index}",
      "-c:s",
      "srt",
      "-f",
      "srt",
      "pipe:1"
    ]
  end

  # Deliberately NOT canonicalized through Language.normalize/1: that collapses "chi"/"zho"
  # (ambiguous between "zh" and Cantonese's "cn") down to one value, indistinguishable from an
  # explicitly Mandarin-only "cmn" track once both land on "zh" — exactly the precision
  # Cinder.Subtitles.Sync.Reference.select/4 and Cinder.Subtitles.local_source/4 need to tell a
  # merely-generic Chinese track from a definitively-Mandarin one when matching a Cantonese
  # request (#573). Language.known?/1 still validates the code is one this registry recognises;
  # the value returned is the raw, lowercased, trimmed tag itself.
  defp subtitle_language(%{"tags" => %{"language" => language}}) when is_binary(language) do
    code = language |> String.trim() |> String.downcase()
    if Language.known?(code), do: code, else: "und"
  end

  defp subtitle_language(_), do: "und"

  defp disposition?(%{"disposition" => disposition}, key) when is_map(disposition) do
    Map.get(disposition, key, 0) == 1
  end

  defp disposition?(_, _), do: false

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
  defp ffmpeg_bin, do: Application.get_env(:cinder, :ffmpeg_bin, "ffmpeg")

  # Test seam only — production never sets these, matching `AudiobookSources.max_tracks/0`'s own
  # `Application.get_env/3`-with-module-attribute-default convention (itself mirroring this
  # module's own `:ffprobe_bin` override). A behaviour callback's arity is fixed, so unlike
  # `BookArchive.Rar.extract/3` these bounds cannot be threaded through as an `opts` argument.
  defp probe_timeout_ms,
    do: Application.get_env(:cinder, :ffprobe_probe_timeout_ms, @probe_timeout_ms)

  defp health_timeout_ms,
    do: Application.get_env(:cinder, :ffprobe_health_timeout_ms, @health_timeout)

  defp subtitle_tracks_timeout_ms,
    do:
      Application.get_env(
        :cinder,
        :ffprobe_subtitle_tracks_timeout_ms,
        @subtitle_tracks_timeout_ms
      )

  defp extract_timeout_ms,
    do: Application.get_env(:cinder, :ffmpeg_extract_timeout_ms, @extract_timeout_ms)

  defp ffmpeg_executable! do
    case System.find_executable(ffmpeg_bin()) do
      nil ->
        System.cmd(ffmpeg_bin(), [])
        ffmpeg_bin()

      executable ->
        executable
    end
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, stderr} -> String.trim(stderr)
      {:error, _} -> ""
    end
  end

  # Resolves `bin` on `PATH` exactly like `System.cmd/3` would (which `Port.open` does not do for
  # `:spawn_executable`), then runs it as a supervised `Port`, killing it by OS pid if it is still
  # running at `timeout_ms`. See the moduledoc's "Bounded subprocess execution" section for why.
  #
  # A missing binary raises `ErlangError{original: :enoent}` from `System.cmd/3` today; reproduced
  # here explicitly (rather than left as a byproduct of some other call) so every caller's
  # existing missing-binary handling — and its own tests — keep seeing the identical shape.
  defp run_bounded(bin, args, timeout_ms, opts) do
    case System.find_executable(bin) do
      nil -> {:error, %ErlangError{original: :enoent}}
      exe -> open_and_supervise(exe, args, timeout_ms, opts)
    end
  end

  defp open_and_supervise(exe, args, timeout_ms, opts) do
    port = Port.open({:spawn_executable, exe}, port_options(args, opts))
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    supervise(port, deadline, [])
  catch
    :error, reason -> {:error, {:port_open_failed, reason}}
  end

  defp port_options(args, opts) do
    base = [:binary, :exit_status, :use_stdio, args: args]

    base =
      if Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout | base], else: base

    case Keyword.get(opts, :env) do
      nil -> base
      env -> [{:env, charlist_env(env)} | base]
    end
  end

  # `Port.open`'s `:env` option wants `{charlist, charlist}` pairs, unlike `System.cmd/3`'s own
  # `:env` option (which accepts plain strings).
  defp charlist_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  # Accumulates stdout exactly like `System.cmd/3` returns it (iodata built up, then flattened),
  # bounded by an ABSOLUTE deadline (`started_at + timeout_ms`, carried through recursion as
  # `deadline` itself so it cannot drift) rather than a per-message `after` — mirrors
  # `BookArchive.Rar.supervise/6`'s own deadline arithmetic.
  #
  # `remaining` (not a fixed poll tick) is recomputed and re-armed as the `after` value on EVERY
  # receive: unlike `BookArchive.Rar.supervise/6`, which must wake periodically regardless of
  # messages to re-measure `dir_size` against its expansion ceiling, this loop has no secondary
  # condition to poll — so a fixed tick would buy nothing and, worse, is actively wrong. A fixed
  # `after` timer restarts on every matched message, so a subprocess emitting `:data` faster than
  # the tick interval (`extract_subtitle/2`'s ffmpeg piping SRT to stdout on a pathological
  # stream is a real example, not a hypothetical one) would starve the `after` clause forever and
  # this call would never time out at all — exactly the failure this whole module exists to
  # prevent. Recomputing `remaining` from a fixed deadline before every `receive` closes that gap:
  # the deadline fires the instant it is reached regardless of how much data arrived beforehand.
  defp supervise(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_and_reap(port)
    else
      receive do
        {^port, {:data, data}} ->
          supervise(port, deadline, [data | acc])

        {^port, {:exit_status, status}} ->
          # No further messages for this port should exist, since every `:data` message was
          # already consumed above in send order before `:exit_status` — drained defensively
          # regardless, so a trapless caller (the poller GenServers) can never see a stray
          # message past this return.
          drain_immediate(port)
          {:ok, IO.iodata_to_binary(Enum.reverse(acc)), status}
      after
        remaining -> kill_and_reap(port)
      end
    end
  end

  # Kills the OS process, waits up to `@reap_wait_ms` (an absolute deadline, not reset by each
  # drained message — a killed-but-still-writing process must not extend the wait) for it to
  # actually exit, then closes the port and drains anything left in the mailbox regardless of
  # whether the reap succeeded. Neither poller GenServer traps exits or has a catch-all
  # `handle_info/2` (see the moduledoc): a `{port, {:data, _}}` or `{port, {:exit_status, _}}`
  # surviving past this function's return would crash it with `FunctionClauseError`, so this must
  # guarantee zero port messages remain queued — not merely best-effort drain them.
  defp kill_and_reap(port) do
    kill(port)
    reap(port, System.monotonic_time(:millisecond) + @reap_wait_ms)
    close_port(port)
    drain_immediate(port)
    {:error, :timeout}
  end

  defp reap(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^port, {:exit_status, _status}} -> :ok
        {^port, {:data, _data}} -> reap(port, deadline)
      after
        remaining -> :ok
      end
    end
  end

  # `Port.close/1` raises `ArgumentError` if the port already closed on its own (the reaped
  # process exited and the port was already consumed by `reap/2`'s `:exit_status` clause) —
  # checking `Port.info/1` first avoids that in the common case, `rescue` covers the unavoidable
  # race between the check and the call.
  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Non-blocking: drains every message already queued for `port` without waiting for more. Used
  # both after a clean exit (defensive) and after `kill_and_reap/1` gives up, so a trapless caller
  # never sees a port message once this module has returned.
  defp drain_immediate(port) do
    receive do
      {^port, _message} -> drain_immediate(port)
    after
      0 -> :ok
    end
  end

  # Mirrors `BookArchive.Rar.kill/1` / `Cinder.Disk.CommandProbe.kill/1` exactly: the OS pid
  # behind a `Port` is not otherwise reachable, and `Port.close/1` alone does not guarantee the
  # process (or, for the shell-wrapped `extract_subtitle/2` call, its child) actually stops. The
  # shell wrapper's `exec "$@"` (see `extract_subtitle/2`) is what makes this `os_pid` `ffmpeg`
  # itself rather than the wrapping `/bin/sh`, so killing it here kills the real work.
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd(
        "/bin/sh",
        ["-c", ~S|kill -KILL "$1"|, "kill", Integer.to_string(pid)],
        stderr_to_stdout: true
      )
    end

    :ok
  catch
    _kind, _reason -> :ok
  end
end
