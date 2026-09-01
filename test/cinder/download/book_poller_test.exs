defmodule Cinder.Download.BookPollerTest do
  @moduledoc """
  The B4b vertical slice: an approved book target with an in-flight grab is tracked to completion,
  validated, published, and shown as available — and the races that could double-grab or
  double-import it are fenced.

  Real filesystem and real `PathPolicy` on purpose: publication is a filesystem effect, and the
  guarantees worth testing (the file lands under the library root, an existing file is never
  overwritten, a rejected payload leaves nothing behind) are only meaningful against real disk.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Download
  alias Cinder.Download.{BookPoller, Intent}
  alias Cinder.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # The in-flight content gate asks the client what files the job will deliver. Default to a
    # clean payload; the blocked-content test overrides this with its own expectation.
    stub(Cinder.Download.ClientMock, :files, fn _id -> {:ok, ["The Dispossessed.epub"]} end)
    :ok
  end

  @moduletag :tmp_dir

  describe "advance_downloading" do
    test "a completed download is published and the target goes available", ctx do
      %{grab: grab, target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(release_dir)

      poll!()

      target = Repo.reload!(target)
      assert target.status == :available

      file = Repo.get_by!(BookFile, book_target_id: target.id)

      expected =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert file.path == expected
      assert file.format == :epub
      assert File.read!(expected) == epub_bytes()

      # The grab is the transient row: it exists only while a download is in flight.
      refute Repo.get(BookGrab, grab.id)
    end

    test "a payload carrying blocked content is refused mid-download", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      # The client reports the job will deliver an executable alongside the book. Vetting has to
      # happen HERE, during the download: `BookSources` silently filters non-book files at import
      # time, so the book would otherwise publish and the blocked payload never be reported.
      stub(Cinder.Download.ClientMock, :files, fn _id ->
        {:ok, ["The Dispossessed.epub", "setup.exe"]}
      end)

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 1_000}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      poll!()

      target = Repo.reload!(target)
      assert target.status == :held
      # The verdict's detail names the offending file. `ContentPolicy.detail/1` sanitizes it for
      # exactly this surface, and without it an operator is told "blocked_content" about a payload
      # they cannot inspect — the grab that carried the download id is deleted by the same hold.
      assert target.hold_reason == "blocked_content: download contains setup.exe"
      assert Repo.all(BookGrab) == []
    end

    test "a failed client removal survives as a durable cleanup record, and a later pass drains it",
         ctx do
      %{target: target} = downloading(ctx, "book.epub")

      stub(Cinder.Download.ClientMock, :files, fn _id ->
        {:ok, ["The Dispossessed.epub", "setup.exe"]}
      end)

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 1_000}}
      end)

      # #398: the immediate best-effort removal fails transiently (client restarting, an API
      # timeout) — the exact failure the durable record has to survive.
      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> {:error, :timeout} end)

      capture_log(fn -> poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      # The grab — previously the only record of `download_id`/`download_protocol` — is gone,
      # same as before the fix.
      assert Repo.all(BookGrab) == []

      # A durable download_intents row now survives the failed removal, carrying exactly what a
      # retry needs: the remote id and protocol the deleted grab used to be the sole owner of.
      intent = Repo.get_by!(Intent, kind: :book_target, target_id: target.id)
      assert intent.status == :cleanup_pending
      assert intent.remote_id == "remote-1"
      assert intent.protocol == :torrent

      # Simulate the bounded retry becoming due — BookPoller reconciles pending intents every
      # tick, but a failed attempt backs off rather than retrying immediately.
      intent |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()

      # The later pass succeeds: the remote job is actually removed this time.
      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      poll!()

      refute Repo.get(Intent, intent.id)
      # The hold survives untouched — draining the cleanup record is not a target-state change.
      assert Repo.reload!(target).status == :held
    end

    # PR #411 review: `hold_orphaned_target/2`'s catch-all clause for a vanished target was
    # accidentally deleted alongside the dead `remove_from_client/1` it sat next to, so
    # `fail_download/2` raised `FunctionClauseError` for a `nil` `book_target` instead of the
    # no-op it used to be — aborting BEFORE `fence_book_cleanup/1` ever ran and re-opening the
    # exact leaked-remote-job bug this PR closes, just via a different trigger.
    #
    # `grab.book_target` is `nil` only when the target row is gone by the time
    # `Books.Grabs.list_downloading/0`'s SEPARATE follow-up preload query runs (it is not a
    # same-statement join) — reachable in production via a concurrent target deletion landing in
    # that gap. `book_grabs.book_target_id` cascades on delete
    # (`references(:book_targets, on_delete: :delete_all)`), so under the Sandbox's single
    # wrapping transaction (`foreign_keys: :on` is pinned for every env, and toggling the pragma
    # mid-transaction is a documented SQLite no-op) a plain delete of the target takes the grab
    # with it — there is no way to leave the grab behind sandboxed.
    #
    # A Sandbox-safe alternative was ruled out, not skipped: `hold_orphaned_target/2` and
    # `fail_download/2` are `defp` — Elixir does not export private functions, so no test can call
    # them directly — and `advance_downloading/0`'s only route to them is its own internal
    # `Books.Grabs.list_downloading/0` call, which cannot be stubbed (it is a plain context
    # function, not a Mox-mocked behaviour, deliberately per AGENTS.md) or fed a pre-built struct.
    # The OTHER half of this regression — that the durable record still gets fenced regardless of
    # `book_target` — IS Sandbox-safe and has its own direct, zero-risk test just below
    # (`Download.fence_book_cleanup/1` never reads `book_target` at all); this test's job is
    # narrowed to the one claim that genuinely needs a real connection: the dispatch doesn't raise.
    #
    # `@tag :unboxed` (`Cinder.DataCase.setup_sandbox/1`) checks out a REAL, non-sandboxed
    # connection whose writes are actual commits, visible to any other test reading the same
    # tables — unlike every other (Sandboxed, rolled-back) test in this suite. What makes that
    # safe here, and the INVARIANT a future reader must preserve before touching any of it:
    #
    #   `async: false` on THIS module is load-bearing, not incidental. ExUnit runs every
    #   `async: true` module to full completion, concurrently among themselves, BEFORE starting
    #   ANY `async: false` module — which then run one at a time, serially, with no overlap with
    #   each other or with the (already-finished) `async: true` phase. Because this module is
    #   `async: false`, this test's real, committed rows can never be visible while an
    #   `async: true` test (e.g. anything asserting a global `Repo.aggregate(Work/BookGrab/
    #   BookTarget/.., :count)`) is running — that phase is already over by the time this one
    #   starts. Flip this module to `async: true` for speed and that guarantee is gone: this
    #   test's rows would then be a real, live commit visible to whichever `async: true` tests
    #   happen to be running at the same moment, on a shared on-disk SQLite file.
    #
    #   `config/test.exs`'s `pool_size: 1` for `Cinder.Repo` is a second, independent guard — one
    #   physical connection for the whole suite serializes every write regardless of process
    #   count — but do not rely on it alone; it says nothing about which ROWS are visible to a
    #   concurrently-scheduled reader, only that writes cannot literally collide mid-statement.
    #
    #   Cleanup runs in a `try/after` INSIDE this test's own process, not `on_exit/1` — `on_exit/1`
    #   runs in a separate `ExUnit.OnExitHandler` process, and by the time it fires this
    #   connection's owner (the test process) has already exited, so its queries silently no-op
    #   with a `DBConnection.OwnershipError` (verified empirically). `try/after` was checked
    #   reliable on both the pass and the forced-failure path. A unique download id (not the
    #   file's shared `"remote-1"` default) avoids colliding with concurrently-scheduled tests
    #   before that cleanup runs.
    @tag :unboxed
    test "a target that vanished out from under its grab does not raise, and still fences a durable cleanup record",
         ctx do
      # Unique id, not the file's shared "remote-1" default — see the invariant comment above.
      remote_id = "remote-vanished-target-#{System.unique_integer([:positive])}"
      %{grab: grab, target: target, work: work} = downloading(ctx, "book.epub", remote_id)
      profile_id = target.profile_id

      # try/after, not on_exit/1 — see the invariant comment above.
      try do
        Repo.query!("PRAGMA foreign_keys = OFF")
        Repo.delete_all(from t in Cinder.Books.BookTarget, where: t.id == ^target.id)
        Repo.query!("PRAGMA foreign_keys = ON")

        # Sanity check the fixture actually reproduces the race's end state before exercising it
        # (scoped to our own id — an unboxed connection sees every real row, not just ours).
        assert %BookGrab{book_target: nil} =
                 Enum.find(Books.Grabs.list_downloading(), &(&1.id == grab.id))

        stub(Cinder.Download.ClientMock, :files, fn _id ->
          {:ok, ["The Dispossessed.epub", "setup.exe"]}
        end)

        expect(Cinder.Download.ClientMock, :status, fn ^remote_id ->
          {:ok, %{state: :downloading, progress: 0.5, speed: 1_000}}
        end)

        expect(Cinder.Download.ClientMock, :remove, fn ^remote_id, _opts -> {:error, :timeout} end)

        # `poll!()` starts BookPoller via `start_supervised!`, a SEPARATE process. Shared Sandbox
        # mode (`Cinder.DataCase.setup_sandbox/1`'s `shared: true` for `async: false` tests) is
        # what lets every other test's `poll!()` call skip this — `sandbox: false` here checks out
        # a raw connection tied ONLY to this process, so the GenServer needs explicit `allow/3`.
        pid = start_supervised!({BookPoller, interval: 60_000})
        Sandbox.allow(Repo, self(), pid)
        log = capture_log(fn -> assert :ok = BookPoller.poll() end)
        stop_supervised!(BookPoller)

        # `isolate/2` would have swallowed a raise and logged "skipped" — its absence is direct
        # proof `fail_download/2` ran to completion rather than aborting mid-way.
        refute log =~ "skipped"

        refute Repo.get(BookGrab, grab.id)

        intent = Repo.get_by!(Intent, kind: :book_target, target_id: target.id)
        assert intent.status == :cleanup_pending
        assert intent.remote_id == remote_id
        assert intent.protocol == :torrent
      after
        # `work_fixture/2` (via `downloading/2`) also creates a `book_authors` row and a
        # `book_credits` link — neither owned by the work, so deleting the work alone would not
        # cascade them away. Capture the author before the work (and its credit) are gone.
        author_ids =
          Repo.all(
            from c in Cinder.Books.Credit, where: c.work_id == ^work.id, select: c.author_id
          )

        Repo.delete_all(from g in BookGrab, where: g.id == ^grab.id)
        Repo.delete_all(from t in Cinder.Books.BookTarget, where: t.id == ^target.id)

        Repo.delete_all(
          from i in Intent, where: i.kind == :book_target and i.target_id == ^target.id
        )

        Repo.delete_all(from w in Books.Work, where: w.id == ^work.id)
        Repo.delete_all(from a in Cinder.Books.Author, where: a.id in ^author_ids)
        if profile_id, do: Repo.delete_all(from p in Catalog.Profile, where: p.id == ^profile_id)
      end
    end

    # Sandbox-safe complement to the `:unboxed` test above: proves the OTHER half of the same
    # regression — that `Download.fence_book_cleanup/1` fences a durable record regardless of
    # `book_target` — without needing a real connection at all. `fence_book_cleanup/1` never
    # reads `grab.book_target` (only `book_target_id`, `download_id`, `download_protocol`,
    # `release_title`), so a plain struct update reproduces the input shape exactly; no orphaned
    # DB row is required for THIS half of the claim.
    test "fence_book_cleanup/1 fences a durable record from a grab whose book_target is nil",
         ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub", "remote-safe-nil-target")
      grab = %{grab | book_target: nil}

      assert {:ok, [intent_id]} = Download.fence_book_cleanup(grab)

      intent = Repo.get!(Intent, intent_id)
      assert intent.kind == :book_target
      assert intent.target_id == target.id
      assert intent.status == :cleanup_pending
      assert intent.remote_id == "remote-safe-nil-target"
      assert intent.protocol == :torrent

      # The grab is gone (fenced-then-deleted in one transaction) regardless of book_target.
      refute Repo.get(BookGrab, grab.id)
    end

    test "one miss does not destroy a live download", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      # Every adapter derives `:not_found` from a SUCCESSFUL empty queue/history lookup, which is
      # what a client reports for the moment a job moves between the two. Acting on the first
      # sighting made that blip destructive: `fail_download/2` removes the remote job with
      # `delete_files: true`.
      #
      # No `remove` expectation: reaching the client would fail this test.
      expect(Cinder.Download.ClientMock, :status, fn "remote-1" -> {:error, :not_found} end)

      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).status == :monitored
      assert Repo.reload!(grab).import_attempts == 1
    end

    test "a download the client no longer knows about is not left in flight forever", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      # The household deleted the job at the client, or its history rolled over. Sustained, this
      # is terminal — no later tick can find it, and with no search pass in this slice the target
      # would hold its grab forever and refuse any new one. It takes the shared budget first.
      stub(Cinder.Download.ClientMock, :status, fn "remote-1" -> {:error, :not_found} end)
      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      capture_log(fn -> for _tick <- 1..10, do: poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason == "download_missing"
      assert Repo.all(BookGrab) == []
    end

    test "progress is recorded while the download is still running", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.42, speed: 1_000, eta: 60}}
      end)

      poll!()

      grab = Repo.reload!(grab)
      assert grab.download_progress == 0.42
      assert is_nil(grab.content_path)
      # Still monitored, not available: nothing has been imported.
      assert Repo.reload!(target).status == :monitored
    end

    test "a dead download parks the target as held with the client's reason", ctx do
      %{target: target, grab: grab} = downloading(ctx, "book.epub")

      stub(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :error, progress: 0.1, reason: "unpacking failed"}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      capture_log(fn -> for _tick <- 1..10, do: poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      # Rendered, not inspected: a client's own error text is what a household member reads off
      # the target, and `inspect/1` would show it quoted.
      assert target.hold_reason == "unpacking failed"
      refute Repo.get(BookGrab, grab.id)
    end

    test "a transient status error leaves the grab alone to retry", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" -> {:error, :timeout} end)

      capture_log(fn -> poll!() end)

      # No park, no import: an unreachable client is not evidence about the download.
      assert Repo.reload!(target).status == :monitored
      assert Repo.get(BookGrab, grab.id)
    end

    test "a stalled download is left alone while the stall reaper is switched off", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      # Zero speed, zero seeders, no progress for 40 minutes — past `no_seeders_timeout`. The
      # operator has reaping switched off (the shipped default is on; `config/test.exs` turns it
      # off), so nothing may be reaped. `StallReaper.reap?/4` is a pure predicate that knows
      # nothing about the config, so calling it unguarded ignored that switch for books alone.
      #
      # No `remove` expectation: reaching the client would fail this test.
      stall(grab, minutes: 40)

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 0, seeders: 0}}
      end)

      poll!()

      assert Repo.reload!(target).status == :monitored
      assert Repo.get(BookGrab, grab.id)
    end

    test "a stalled download is reaped once the stall reaper is switched on", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      stall_reaper(enabled: true)
      stall(grab, minutes: 40)

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 0, seeders: 0}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      capture_log(fn -> poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason == "stalled"
      assert Repo.all(BookGrab) == []
    end

    test "a download that resumed after a long outage is not reaped by the absolute cap", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      # The app was down for two days while the download kept going. The progress clock on the row
      # is stale by definition, so reading it BEFORE recording this tick's status reaps a healthy
      # job: `max_downloading_timeout` defaults to 24h. Recording first — what `Poller` and
      # `TvPoller` both do — advances the clock on this tick's real forward motion, and the cap
      # then reads the honest value.
      #
      # No `remove` expectation: reaping this download would fail the test.
      stall_reaper(enabled: true)
      stall(grab, minutes: 48 * 60)

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 1_000, seeders: 12}}
      end)

      poll!()

      assert Repo.reload!(target).status == :monitored
      assert Repo.reload!(grab).download_progress == 0.5
    end
  end

  describe "validation refusals" do
    test "an ambiguous multi-book payload holds instead of guessing", ctx do
      %{target: target, release_dir: release_dir, books: books} =
        downloading(ctx, "Book One.epub")

      dir = release_dir
      File.write!(Path.join(dir, "Book Two.epub"), "a different book")

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason =~ "ambiguous_book_files"

      # Nothing was published: a guess is exactly what the contract forbids.
      assert Repo.all(BookFile) == []
      assert File.ls!(books) == []
    end

    test "a still-unsupported archive shape holds rather than being expanded", ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx, "book.epub")
      dir = release_dir
      File.rm!(Path.join(dir, "book.epub"))
      # `.7z` is the one archive shape `Cinder.Library.BookSources` never even attempts to
      # extract (see its own "archive extraction" test coverage) — unlike `.zip`/`.rar`, it
      # cannot depend on whether the test box happens to have the external `unrar` binary.
      File.write!(Path.join(dir, "book.7z"), "archive")

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).status == :held
      assert Repo.reload!(target).hold_reason =~ "unsupported_archive"
      assert Repo.all(BookFile) == []
    end

    test "a zipped release is extracted and published, end to end", ctx do
      %{target: target, release_dir: release_dir, books: books} =
        downloading(ctx, "book.epub")

      File.rm!(Path.join(release_dir, "book.epub"))

      :zip.create(String.to_charlist(Path.join(release_dir, "release.zip")), [
        {~c"The Dispossessed.epub", epub_bytes()}
      ])

      complete_download(release_dir)
      poll!()

      target = Repo.reload!(target)
      assert target.status == :available

      file = Repo.get_by!(BookFile, book_target_id: target.id)

      expected =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert file.path == expected
      assert file.format == :epub
      assert File.read!(expected) == epub_bytes()
    end

    test "a completed download with no content path holds", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      # A client that says "done" but names no payload may just not have published the path yet,
      # so this takes the download budget before it becomes terminal.
      stub(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :completed, progress: 1.0, content_path: nil}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      capture_log(fn -> for _tick <- 1..10, do: poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason == "missing_content_path"
    end

    test "import holds (no attempt bump, no park) when the books root is nearly full", ctx do
      %{grab: grab, target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      # A full disk is fixable and the download is already sitting there, so this must NOT burn the
      # import budget: ten ticks of it would park the target `:held` and turn "free some space"
      # into "notice the hold and re-grab". Both video pollers gate their import the same way.
      complete_download(release_dir)
      set_disk_stub!({:ok, %{free_bytes: 500_000_000, total_bytes: 100_000_000_000}})

      log = capture_log(fn -> poll!() end)

      assert log =~ "nearly full"
      assert Repo.reload!(target).status == :monitored

      grab = Repo.reload!(grab)
      assert grab.import_attempts == 0
      assert grab.content_path == release_dir

      assert Repo.all(BookFile) == []
      assert File.ls!(books) == []
    end
  end

  describe "idempotency" do
    test "repeated ticks cannot double-import", ctx do
      %{target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(release_dir)

      poll!()

      # Second tick: the grab is gone, so there is nothing left to advance and no client call.
      poll!()

      assert [%BookFile{}] = Repo.all(BookFile)
      assert Repo.reload!(target).status == :available

      dir = Path.join([books, "Ursula K. Le Guin", "The Dispossessed"])
      assert File.ls!(dir) == ["The Dispossessed.epub"]
    end

    test "an existing file at the destination is kept, never overwritten", ctx do
      %{target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      dest_dir = Path.join([books, "Ursula K. Le Guin", "The Dispossessed"])
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, "The Dispossessed.epub")
      File.write!(dest, epub_bytes() <> "operator")

      complete_download(release_dir)

      poll!()

      # Automatic upgrades and conversion are parked for the first release: the existing bytes win.
      assert File.read!(dest) == epub_bytes() <> "operator"
      assert Repo.reload!(target).status == :available

      file = Repo.get_by!(BookFile, book_target_id: target.id)
      assert file.path == dest

      # The recorded size describes the file that is ACTUALLY at the destination, not the source
      # that was refused. Recording the source's size here would have the catalog claim a size
      # the published file does not have.
      assert file.size == byte_size(epub_bytes() <> "operator")
    end

    test "a directory at the destination is refused, not recorded as a book", ctx do
      %{target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      # Something already occupies the exact destination path, but it is a DIRECTORY. Adopting it
      # would publish an `:available` target whose file row points at something the consumer
      # cannot read.
      dest_dir = Path.join([books, "Ursula K. Le Guin", "The Dispossessed"])
      File.mkdir_p!(Path.join(dest_dir, "The Dispossessed.epub"))

      complete_download(release_dir)
      poll!()

      assert Repo.all(BookFile) == []
      assert File.dir?(Path.join(dest_dir, "The Dispossessed.epub"))
      assert Repo.reload!(target).status == :monitored

      # Ten more ticks: the attempt budget runs out and the target must HOLD with a readable
      # reason. Regression — the refusal reason is a TUPLE, and formatting it with `to_string/1`
      # raised `Protocol.UndefinedError` inside the hold. `isolate/2` swallowed that raise, so the
      # grab neither held nor cleared and every later tick re-raised forever. A single-tick
      # assertion cannot see this: an isolated raise leaves exactly the same state as a refusal.
      #
      # `stub`, not `expect`: once the hold lands the grab is deleted, so the remaining ticks find
      # no work and never reach the client. Counting calls would assert the loop's shape rather
      # than its outcome.
      stub(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
      end)

      for _tick <- 1..10, do: poll!()

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason =~ "unexpected_destination_type"
      assert Repo.all(BookGrab) == []
    end

    test "a path another target already claims is refused without destroying the file", ctx do
      # Two distinct works whose author/title fold to the SAME destination path. The second
      # import must lose the `book_files.path` unique index and roll its stage back — and that
      # rollback must not delete the first target's published file.
      %{target: first, books: books, release_dir: first_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(first_dir)
      poll!()

      dest =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert File.read!(dest) == epub_bytes()
      assert Repo.reload!(first).status == :available

      # A second target for an identically-named work by the same author.
      %{target: second, release_dir: second_dir} =
        downloading(ctx, "The Dispossessed.epub", "remote-2")

      File.write!(Path.join(second_dir, "The Dispossessed.epub"), epub_bytes())
      complete_download(second_dir, "remote-2")
      poll!()

      # The first target's file is untouched, and still the only row for that path.
      assert File.read!(dest) == epub_bytes()
      assert [%BookFile{book_target_id: owner}] = Repo.all(BookFile)
      assert owner == first.id

      # The second target parked visibly rather than silently reporting success.
      second = Repo.reload!(second)
      assert second.status == :held
      assert second.hold_reason == "book_file_exists"
    end

    test "a replayed import converges instead of demoting an available target", ctx do
      %{target: target, books: books, release_dir: release_dir, grab: grab} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(release_dir)
      poll!()

      dest =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert Repo.reload!(target).status == :available
      assert %BookFile{id: file_id} = Repo.get_by!(BookFile, book_target_id: target.id)

      # Simulate a crash (or a swallowed Repo error) between the committed catalog write and the
      # grab delete: the import succeeded, but the grab survives with its content_path, so the
      # next tick re-imports the same source to the same destination.
      {:ok, _replayed} =
        Books.Grabs.create(target.id, grab.download_id, :torrent, grab.release_title)

      complete_download(release_dir)
      poll!()

      # The replay is a no-op, NOT a `book_file_exists` conflict: the row that "conflicts" is this
      # target's own. Demoting a target whose file is on disk and in the catalog to :held was the
      # bug.
      target = Repo.reload!(target)
      assert target.status == :available
      assert is_nil(target.hold_reason)

      assert [%BookFile{id: ^file_id}] = Repo.all(BookFile)
      assert File.read!(dest) == epub_bytes()

      # The grab is consumed, so the replay does not loop forever.
      assert Repo.all(BookGrab) == []
    end
  end

  describe "grab uniqueness" do
    test "a target cannot hold two grabs at once", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      # The DB fence, asserted directly: the poller's own double-grab protection is this index.
      assert {:error, :book_grab_exists} =
               Books.Grabs.create(target.id, "remote-2", :torrent, "Another Release")
    end
  end

  # Drives the free-disk prober (`Cinder.Test.StubDisk`) for a test's duration; restored on exit.
  defp set_disk_stub!(result) do
    saved = Application.get_env(:cinder, :disk_stats_stub)
    Application.put_env(:cinder, :disk_stats_stub, result)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:cinder, :disk_stats_stub),
        else: Application.put_env(:cinder, :disk_stats_stub, saved)
    end)
  end

  # --- fixtures ---

  defp poll! do
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()
    stop_supervised!(BookPoller)
  end

  # Ages both clocks the reaper reads: `updated_at` drives the seed-aware zero-speed window and
  # `download_progress_at` the protocol-agnostic absolute cap. Written directly because the
  # context deliberately has no "pretend this grab is old" API.
  defp stall(grab, minutes: minutes) do
    then = DateTime.add(DateTime.utc_now(:second), -minutes * 60, :second)

    Repo.update_all(from(g in BookGrab, where: g.id == ^grab.id),
      set: [updated_at: then, download_progress_at: then]
    )
  end

  defp stall_reaper(opts) do
    saved = Application.get_env(:cinder, Cinder.Download.StallReaper, [])
    Application.put_env(:cinder, Cinder.Download.StallReaper, Keyword.merge(saved, opts))
    on_exit(fn -> Application.put_env(:cinder, Cinder.Download.StallReaper, saved) end)
  end

  defp complete_download(release_dir, remote_id \\ "remote-1") do
    expect(Cinder.Download.ClientMock, :status, fn ^remote_id ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)
  end

  defp downloading(ctx, filename, remote_id \\ "remote-1")

  defp downloading(%{tmp_dir: tmp} = ctx, filename, "remote-1") do
    build_target(real_book_library(tmp), ctx, filename, "remote-1")
  end

  # A second target in an ALREADY-configured library: `real_book_library/1` rewrites the app env
  # and registers its own `on_exit`, so calling it twice in one test would stack restores. The
  # roots are re-derived from the same tmp_dir, and the existing profile is reused — a library
  # path is unique across profiles, and two targets sharing one root is the case under test.
  defp downloading(%{tmp_dir: tmp} = ctx, filename, remote_id) do
    roots = %{downloads: Path.join(tmp, "downloads"), books: Path.join(tmp, "books")}
    build_target(roots, ctx, filename, remote_id)
  end

  defp build_target(%{downloads: downloads, books: books}, _ctx, filename, remote_id) do
    release_dir = Path.join(downloads, "release-#{remote_id}")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, filename), epub_bytes())

    profile = ebook_profile(books)

    work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, remote_id, :torrent, "The Dispossessed EPUB")

    %{
      grab: grab,
      target: target,
      work: work,
      books: books,
      downloads: downloads,
      release_dir: release_dir
    }
  end

  # One `:ebook` profile per library root: `media_profiles.library_path` is unique, so a second
  # target in the same test reuses the first profile rather than creating a colliding one.
  defp ebook_profile(books) do
    case Enum.find(Catalog.list_profiles(:ebook), &(&1.library_path == books)) do
      %Catalog.Profile{} = existing ->
        existing

      nil ->
        {:ok, profile} =
          Catalog.create_profile(%{
            name: "Ebooks #{System.unique_integer([:positive])}",
            kind: :ebook,
            handling: :standard,
            library_path: books
          })

        profile
    end
  end

  # A conforming EPUB OCF container prefix — what `BookSources`' signature check requires: a
  # 30-byte stored-entry local file header, then the mandatory `mimetype` entry and its content.
  defp epub_bytes do
    <<"PK", 3, 4, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 20, 0, 0, 0, 8, 0, 0,
      0>> <> "mimetype" <> "application/epub+zip"
  end

  defp real_book_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    books = Path.join(tmp, "books")
    File.mkdir_p!(downloads)
    File.mkdir_p!(books)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :books_library_path,
      :move_on_import
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :books_library_path, books)
    Application.put_env(:cinder, :move_on_import, false)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    %{downloads: downloads, books: books}
  end

  defp work_fixture(title, author_name) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: title,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: author_name,
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    Books.get_work(work.id)
  end
end
