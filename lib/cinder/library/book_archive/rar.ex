defmodule Cinder.Library.BookArchive.Rar do
  @moduledoc """
  Bounded RAR extraction (`.rar`, `.cbr`, split `.rNN` volumes), via the external `unrar`
  binary, only when it is present.

  ## Why a supervised subprocess rather than in-process control

  Unlike `Cinder.Library.BookArchive.Zip`, this module cannot instrument decompression at the
  byte level — `unrar` is closed-source (RARLAB freeware, not open source), and RAR's
  compression algorithms are not reimplementable the way ZIP/DEFLATE's small, documented format
  is. So the expanded-size ceiling here is enforced by SUPERVISION rather than by streaming
  control: the extraction runs through `Cinder.BoundedCommand.run/4`, whose `:check` option
  measures the destination directory's actual on-disk size every poll interval and kills the OS
  process by pid the first time it is over the ceiling.

  This is genuinely coarser-grained than the ZIP path's byte-exact, per-chunk enforcement: the
  bound is poll-interval × unrar's max write throughput in that window, not exact. It is still
  a real "during, not after" defense — the process is killed while it is still writing, not
  once the disk is already full — just without the ZIP path's precision, because nothing here
  can see inside `unrar` the way `:zlib` streaming can be driven directly.

  A wall-clock ceiling runs alongside the size poll for the same reason `-p-` (never prompt for
  a password) is passed explicitly: a password-protected or otherwise-stuck archive must not
  leave a hung subprocess parked forever on a poller tick. Either ceiling kills the same way.
  The `unrar lb` listing call that runs *before* extraction starts goes through the same
  `BoundedCommand.run/4` as extraction itself (`@list_timeout_ms`, a separate, much shorter
  ceiling). `Task.shutdown(:brutal_kill)` only kills the *Elixir* task, not `unrar`
  itself when it never reads stdin, which is exactly the defect issue #510 closed for this
  listing call and for `Cinder.Library.MediaInfo.Ffprobe.health/0` and
  `Cinder.Library.AudioProbe.Ffprobe.probe/1`. A hung listing call is otherwise
  indistinguishable from a hung extraction from the poller's point of view — both would occupy
  a tick indefinitely — so both need the same guarantee.

  ## Entry safety

  `unrar lb -p-` (bare list, no password prompt) enumerates entries before any extraction
  starts; each raw name is validated with the exact same `Cinder.Library.BookArchive.EntryPath`
  check the ZIP path uses, refusing the whole archive on any traversal or absolute-path entry
  rather than trusting `unrar`'s own path handling — `unrar` is closed-source and not something
  this module can audit the way `Cinder.Library.BookArchive.Zip`'s moduledoc documents having
  read Erlang's `zip.erl` directly. `-ol-` ("process symbolic links as... skip") is passed to
  `unrar x` as defense in depth at the tool level, on top of the entry-name check.

  Listing and extraction are two separate invocations of that same closed-source binary, so
  nothing so far actually confirms `unrar x` wrote what `unrar lb` listed, or honoured `-ol-` —
  a listing/extraction divergence is exactly the shape of CVE-2022-30333. `Cinder.Library.
  BookArchive.Zip` gets "never anything but a regular file or a directory" structurally, by
  construction: it cannot write a symlink no matter what an entry claims. This module cannot
  make that same structural claim about `unrar`, so it is verified instead — after `unrar x`
  returns and before the scratch directory is ever handed to `resolve_fun`, every path under
  `dest_dir` is `lstat`'d (never `stat` — a symlink must be seen as itself, not followed to
  whatever it targets) and the whole archive is refused as `:archive_entry_unsafe` if anything
  but a regular file or a directory turns up. The walk itself only ever descends into an entry
  `lstat` confirms is a genuine directory, so a symlinked directory is refused rather than
  walked into.
  """

  alias Cinder.BoundedCommand
  alias Cinder.Library.BookArchive.EntryPath

  # Same rationale as the ZIP path's identical constants — see
  # `Cinder.Library.BookArchive.Zip`'s module attributes.
  @max_entries 500
  @max_expanded_size 1_000_000_000

  # How often the destination directory's size is measured while `unrar` runs, and the
  # resulting worst-case overshoot bound (poll interval × throughput) — see the moduledoc.
  @poll_interval 200

  # `unrar lb` only reads the archive's header/central-directory table, never decompresses
  # entry content — the same "cheap, should be fast" shape as `MediaInfo.Ffprobe.health/0`'s
  # `-version` call, not `AudioProbe.Ffprobe.probe/1`'s full-file read. 5s is generous headroom
  # for a large multi-volume archive's header read on a slow/network disk while still leaving
  # `unrar x`'s own 60s `@max_duration_ms` ceiling as the dominant, expected wait for legitimate
  # work — a hung or password-blocked `lb` must not park a poller tick for anywhere near that
  # long before extraction (which has its own ceiling) ever gets a chance to run.
  @list_timeout_ms 5_000

  # No legitimate single-book-release extraction should ever take this long; a stuck or
  # password-blocked process is killed rather than left occupying a poller tick indefinitely.
  @max_duration_ms 60_000

  @doc "Whether `unrar` is on `PATH`, checked fresh — never cached, never compile-time."
  @spec available?() :: boolean()
  def available?, do: not is_nil(unrar_bin())

  @doc """
  Extracts `archive_path` into `dest_dir` (already created, already trusted). `{:error,
  :unsupported_archive}` when `unrar` is absent — the same exact reason this whole extraction
  feature is skipped for today, deliberately unchanged.

  `opts` overrides ceilings/timing below their defaults — a test seam, matching
  `Cinder.Library.BookArchive.Zip.extract/3`'s own.
  """
  @spec extract(String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :unsupported_archive
             | :archive_entry_limit
             | :archive_size_limit
             | :archive_timeout
             | :archive_entry_unsafe
             | :archive_corrupt
             | {:port_open_failed, term()}
             | Exception.t()}
  def extract(archive_path, dest_dir, opts \\ []) do
    case unrar_bin() do
      nil -> {:error, :unsupported_archive}
      bin -> do_extract(bin, archive_path, Path.expand(dest_dir), opts)
    end
  end

  defp unrar_bin, do: System.find_executable("unrar")

  defp do_extract(bin, archive_path, dest_dir, opts) do
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    max_expanded_size = Keyword.get(opts, :max_expanded_size, @max_expanded_size)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval)
    max_duration_ms = Keyword.get(opts, :max_duration_ms, @max_duration_ms)
    list_timeout_ms = Keyword.get(opts, :list_timeout_ms, @list_timeout_ms)

    with {:ok, entries} <- list_entries(bin, archive_path, list_timeout_ms),
         :ok <- check_entry_count(entries, max_entries),
         :ok <- validate_entries(entries, dest_dir),
         :ok <-
           run_extraction(
             bin,
             archive_path,
             dest_dir,
             max_expanded_size,
             poll_interval,
             max_duration_ms
           ) do
      verify_extracted_regular(dest_dir)
    end
  end

  # See the moduledoc's "Entry safety" section: `unrar x`'s own output is not trusted to have
  # honoured `-ol-`, so every path actually written is `lstat`'d (never `stat`) after the fact
  # and the whole archive is refused the moment anything but a regular file or a directory
  # turns up. Recursion only ever descends into an entry `lstat` itself confirms is a genuine
  # directory, so a symlinked directory is refused here rather than walked into.
  defp verify_extracted_regular(dir) do
    case File.ls(dir) do
      {:ok, names} -> verify_names_regular(dir, names)
      {:error, _reason} -> {:error, :archive_entry_unsafe}
    end
  end

  defp verify_names_regular(dir, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case verify_entry_regular(Path.join(dir, name)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_entry_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> verify_extracted_regular(path)
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :archive_entry_unsafe}
      {:error, _reason} -> {:error, :archive_entry_unsafe}
    end
  end

  # Through `Cinder.BoundedCommand.run/4` (#510): `Task.shutdown(:brutal_kill)` (the previous
  # implementation) only killed the *Elixir* task, not `unrar` itself when it never reads stdin,
  # so a hung/slow `lb` used to keep running past the reported timeout. A timeout maps to the same
  # `:archive_corrupt` a nonzero exit already returns, so no caller needs a new clause — both mean
  # "this archive cannot be listed," and a hung `lb` is exactly as unusable to the caller as a
  # corrupt one.
  defp list_entries(bin, archive_path, list_timeout_ms) do
    case BoundedCommand.run(bin, ["lb", "-p-", "--", archive_path], list_timeout_ms,
           stderr_to_stdout: true
         ) do
      {:ok, output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {:ok, _output, _status} -> {:error, :archive_corrupt}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp check_entry_count(entries, max_entries) do
    if length(entries) > max_entries, do: {:error, :archive_entry_limit}, else: :ok
  end

  defp validate_entries(entries, dest_dir) do
    Enum.reduce_while(entries, :ok, fn name, :ok ->
      case EntryPath.safe(name, dest_dir) do
        {:ok, _target} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The expanded-size ceiling is a `:check` on `Cinder.BoundedCommand.run/4`: every
  # `poll_interval` it measures `dest_dir` and halts `unrar` once the directory crosses the
  # ceiling, on a schedule continuous `unrar` output cannot reset (#506). The wall-clock ceiling
  # is the run's own timeout. A failed port open is a fact about the host, not the archive, so it
  # passes through as itself rather than as `:archive_corrupt`, which `BookPoller` treats as
  # permanent.
  defp run_extraction(
         bin,
         archive_path,
         dest_dir,
         max_expanded_size,
         poll_interval,
         max_duration_ms
       ) do
    args = ["x", "-y", "-p-", "-ol-", "--", archive_path, dest_dir <> "/"]
    size_check = fn -> size_check(dest_dir, max_expanded_size) end

    case BoundedCommand.run(bin, args, max_duration_ms,
           stderr_to_stdout: true,
           check: {poll_interval, size_check}
         ) do
      {:ok, _output, 0} -> check_final_size(dest_dir, max_expanded_size)
      {:ok, _output, _nonzero} -> {:error, :archive_corrupt}
      {:error, {:halted, reason}} -> {:error, reason}
      {:error, {:timeout, _output}} -> {:error, :archive_timeout}
      {:error, _reason} = error -> error
    end
  end

  # `dir_size/1` can be an expensive tree walk, which is why it runs on `poll_interval` and not on
  # every message from `unrar`.
  defp size_check(dest_dir, max_expanded_size) do
    if dir_size(dest_dir) > max_expanded_size, do: {:halt, :archive_size_limit}, else: :ok
  end

  # The zero-exit path used to return :ok unconditionally — a fast extraction that already
  # exceeded the cap on disk but finished (and exited 0) before the first poll ever fired slipped
  # through uncaught (#506). The process has already exited here, so there is nothing left to
  # kill; only the disk needs to be judged.
  defp check_final_size(dest_dir, max_expanded_size) do
    if dir_size(dest_dir) > max_expanded_size,
      do: {:error, :archive_size_limit},
      else: :ok
  end

  # Never `Path.wildcard` — proven in development that its `**` glob traversal silently follows
  # a symlinked directory straight through to whatever it targets, which would source this
  # in-progress budget's numbers from outside `dir` entirely (and, on a mid-extraction poll,
  # could walk an arbitrarily large or slow tree the ceiling was never meant to measure).
  # Recursion here only ever descends into an entry `lstat` itself confirms is a genuine
  # directory, matching `verify_extracted_regular/1`'s own walk below.
  defp dir_size(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(names, 0, &(&2 + entry_size(Path.join(dir, &1))))
      {:error, _reason} -> 0
    end
  end

  defp entry_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> dir_size(path)
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _other_or_vanished -> 0
    end
  end
end
