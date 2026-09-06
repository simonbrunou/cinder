defmodule Cinder.Download.AudiobookPollerTest do
  @moduledoc """
  The B7b vertical slice: an approved audiobook target with an in-flight grab is tracked to
  completion, its multi-track payload is validated, resolved, and published ATOMICALLY as one
  target, and the target is shown available — mirroring `Cinder.Download.BookPollerTest`'s own
  reasoning for why this runs against a real filesystem and real `PathPolicy`.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Download.{BookPoller, Intent}
  alias Cinder.Library
  alias Cinder.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cinder.Download.ClientMock, :files, fn _id -> {:ok, []} end)
    # Not under test here (see AudiobookshelfScanTest) — a bare stub keeps every :available
    # transition in this file from tripping Mox's global-mode "no expectation" guard.
    stub(Cinder.Library.AudiobookServerMock, :scan, fn -> :ok end)
    :ok
  end

  @moduletag :tmp_dir

  describe "atomic multi-track import" do
    test "a single M4B imports with no track/disc segment in its destination path", ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(ctx, %{"The Dispossessed.m4b" => m4b_bytes()})

      complete_download(release_dir)
      poll!()

      dest =
        Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.m4b"])

      assert File.read!(dest) == m4b_bytes()
      assert [%BookFile{path: ^dest, track_number: nil, disc_number: nil}] = Repo.all(BookFile)
      assert Repo.reload!(target).status == :available
    end

    test "a correctly-numbered multi-track MP3 set imports as N rows, ordered by tag evidence
          even out of lexical order",
         ctx do
      # Same reduced filename stem via an identical basename in distinct subdirectories (a real
      # disc-pack shape) — proves tag evidence outranks filename order, not merely agrees with it.
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(ctx, %{
          "B/Recording.mp3" => mp3_bytes(),
          "A/Recording.mp3" => mp3_bytes()
        })

      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      b_source = Path.join(release_dir, "B/Recording.mp3")
      a_source = Path.join(release_dir, "A/Recording.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^b_source -> {:ok, probe(track_tag: 2, album_tag: "The Dispossessed")}
        ^a_source -> {:ok, probe(track_tag: 1, album_tag: "The Dispossessed")}
      end)

      complete_download(release_dir)
      poll!()

      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])

      assert File.ls!(dir) |> Enum.sort() == [
               "01 - The Dispossessed.mp3",
               "02 - The Dispossessed.mp3"
             ]

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
      assert Enum.map(files, & &1.track_number) |> Enum.sort() == [1, 2]
      assert Repo.reload!(target).status == :available
    end

    test "a tag/filename contradiction on the same file holds :track_order_contradictory", ctx do
      %{target: target, release_dir: release_dir} =
        downloading(ctx, %{
          "01 - Recording.mp3" => mp3_bytes(),
          "02 - Recording.mp3" => mp3_bytes()
        })

      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      one = Path.join(release_dir, "01 - Recording.mp3")
      two = Path.join(release_dir, "02 - Recording.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^one -> {:ok, probe(track_tag: 3, album_tag: "Book")}
        ^two -> {:ok, probe(track_tag: 2, album_tag: "Book")}
      end)

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      reloaded = Repo.reload!(target)
      assert reloaded.status == :held
      assert reloaded.hold_reason == "track_order_contradictory"
      assert Repo.all(BookFile) == []
      assert Repo.all(BookGrab) == []
    end

    test "zero numeric evidence anywhere holds :track_order_unknown", ctx do
      %{target: target, release_dir: release_dir} =
        downloading(ctx, %{
          "A/Recording.mp3" => mp3_bytes(),
          "B/Recording.mp3" => mp3_bytes()
        })

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      reloaded = Repo.reload!(target)
      assert reloaded.status == :held
      assert reloaded.hold_reason == "track_order_unknown"
      assert Repo.all(BookFile) == []
    end

    test "one real track plus one unrelated audio file is held, never imported as a spliced book",
         ctx do
      %{target: target, release_dir: release_dir} =
        downloading(ctx, %{
          "The Dispossessed 01.mp3" => mp3_bytes(),
          "A Different Book 02.mp3" => mp3_bytes()
        })

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      reloaded = Repo.reload!(target)
      assert reloaded.status == :held
      assert reloaded.hold_reason == "mixed_book_filenames"
      assert Repo.all(BookFile) == []
    end
  end

  describe "post-import cleanup fencing" do
    test "a failed post-import client removal survives as a durable cleanup record, and a later pass drains it",
         ctx do
      %{downloads: downloads, audiobooks: audiobooks} = real_audiobook_library(ctx.tmp_dir, [])

      saved = Application.get_env(:cinder, :move_on_import, false)
      Application.put_env(:cinder, :move_on_import, true)
      on_exit(fn -> Application.put_env(:cinder, :move_on_import, saved) end)

      release_dir = Path.join(downloads, "release-nzo-audiobook")
      File.mkdir_p!(release_dir)
      File.write!(Path.join(release_dir, "The Dispossessed.m4b"), m4b_bytes())

      profile = audiobook_profile(audiobooks)
      work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
      {:ok, target} = Books.monitor_target(work, :audiobook, profile)

      {:ok, _grab} =
        Books.Grabs.create(target.id, "nzo-audiobook", :usenet, "The Dispossessed Audiobook")

      expect(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-audiobook" ->
        {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
      end)

      # #502: the immediate best-effort removal fails transiently (client restarting, an API
      # timeout) — the exact failure the durable record has to survive.
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "nzo-audiobook", _opts ->
        {:error, :timeout}
      end)

      poll!()

      target = Repo.reload!(target)
      assert target.status == :available
      file = Repo.get_by!(BookFile, book_target_id: target.id)
      assert File.exists?(file.path)

      # The grab is gone (fenced-then-deleted in one transaction) — same outcome as before the fix.
      assert Repo.all(BookGrab) == []

      # A durable download_intents row now survives the failed removal, carrying exactly what a
      # retry needs: the remote id and protocol the deleted grab used to be the sole owner of.
      intent = Repo.get_by!(Intent, kind: :book_target, target_id: target.id)
      assert intent.status == :cleanup_pending
      assert intent.remote_id == "nzo-audiobook"
      assert intent.protocol == :usenet

      # Simulate the bounded retry becoming due — BookPoller reconciles pending intents every
      # tick, but a failed attempt backs off rather than retrying immediately.
      intent |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()

      # The later pass succeeds: the remote job is actually removed this time.
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "nzo-audiobook", _opts -> :ok end)

      poll!()

      refute Repo.get(Intent, intent.id)
      # Draining the cleanup record is not itself a target-state change.
      assert Repo.reload!(target).status == :available
    end

    # #536: a concurrent re-grab reserving a NEW intent for this same target between commit and
    # this post-import fence must never be hijacked (flipped to :cleanup_pending, its own
    # remote_id discarded) — the same `expect_remote_id` guard `fence_movie_cleanup/2`/
    # `fence_episode_cleanup/3` already apply, now closing the gap `fence_book_cleanup/1` had.
    test "finish/3's post-import fence never hijacks a concurrently reserved intent", ctx do
      %{downloads: downloads, audiobooks: audiobooks} = real_audiobook_library(ctx.tmp_dir, [])

      saved = Application.get_env(:cinder, :move_on_import, false)
      Application.put_env(:cinder, :move_on_import, true)
      on_exit(fn -> Application.put_env(:cinder, :move_on_import, saved) end)

      release_dir = Path.join(downloads, "release-nzo-audiobook")
      File.mkdir_p!(release_dir)
      File.write!(Path.join(release_dir, "The Dispossessed.m4b"), m4b_bytes())

      profile = audiobook_profile(audiobooks)
      work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
      {:ok, target} = Books.monitor_target(work, :audiobook, profile)

      {:ok, _grab} =
        Books.Grabs.create(target.id, "nzo-audiobook", :usenet, "The Dispossessed Audiobook")

      # Simulate the race directly: a concurrent re-grab already reserved a brand-new intent for
      # this same target between the import commit and the post-import fence about to run.
      race_intent =
        %Intent{}
        |> Intent.changeset(%{
          operation_key: Ecto.UUID.generate(),
          kind: :book_target,
          target_id: target.id,
          episode_ids: [],
          protocol: :usenet,
          release: %{"title" => "The Dispossessed"},
          status: :submitted,
          remote_id: "nzo-new"
        })
        |> Repo.insert!()

      expect(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-audiobook" ->
        {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
      end)

      # `stub`, not `expect`: the race intent itself is also swept by this same tick's normal
      # `reconcile_pending_intents/1` pass and may call `remove/2` for its OWN remote_id too —
      # an `expect` pinned to a call COUNT would then reject the fence's own removal as "called
      # too many times" for reasons having nothing to do with this fix.
      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn
        "nzo-audiobook", _opts ->
          send(parent, {:removed, "nzo-audiobook"})
          :ok

        _other_id, _opts ->
          :ok
      end)

      poll!()

      assert_receive {:removed, "nzo-audiobook"}

      target = Repo.reload!(target)
      assert target.status == :available
      assert Repo.all(BookGrab) == []

      # The race-winning intent was never hijacked into carrying the OLD download's id — whether
      # this same tick's own unrelated reconcile-pending-intents sweep has since drained it
      # (a natural, correct outcome for an otherwise-unbacked :submitted intent) or not.
      case Repo.get(Intent, race_intent.id) do
        nil -> :ok
        %Intent{remote_id: remote_id} -> assert remote_id == "nzo-new"
      end

      # No second, corrupted intent was created for the old download either.
      refute Repo.get_by(Intent,
               kind: :book_target,
               target_id: target.id,
               remote_id: "nzo-audiobook"
             )
    end
  end

  # The end-to-end regression test for the B7b defect the review found: `BookArchive.finish/2`
  # originally raised `FunctionClauseError` on every SUCCESSFUL audiobook extraction (only
  # `BookSources`' own 3-tuple resolve_fun shape matched), caught only by `isolate/2`'s rescue —
  # a working import looked like an opaque logged failure, and no test anywhere drove a real
  # archive through the actual production path. This one does: a real `.zip` release, downloaded,
  # polled, resolved, staged, and imported through `BookPoller` exactly as a real download client
  # would hand it off.
  describe "archive extraction" do
    test "a real zip archive extracts, resolves, and imports atomically end to end", ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} = downloading(ctx, %{})

      archive = Path.join(release_dir, "release.zip")

      :zip.create(String.to_charlist(archive), [
        {~c"02 - Recording.mp3", mp3_bytes()},
        {~c"01 - Recording.mp3", mp3_bytes()}
      ])

      complete_download(release_dir)
      poll!()
      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])

      assert File.ls!(dir) |> Enum.sort() == [
               "01 - The Dispossessed.mp3",
               "02 - The Dispossessed.mp3"
             ]

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
      assert Repo.reload!(target).status == :available
    end
  end

  describe "atomic partial-failure — fresh import" do
    test "a fault on the Nth of M tracks leaves zero files and zero rows", ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(
          ctx,
          %{
            "01 - Track.mp3" => mp3_bytes(),
            "02 - Track.mp3" => mp3_bytes(),
            "03 - Track.mp3" => mp3_bytes()
          },
          "remote-1",
          barrier: true
        )

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: Path.join(release_dir, "02 - Track.mp3"),
        reason: :eio
      })

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      dest_dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])
      # Track 1 landed and its parent directory was created before track 2's injected failure —
      # rollback removes the FILE it staged (a fresh, non-replace stage has no backup, so
      # `rollback_uncommitted_stage/1` removes the landed destination outright), but never prunes
      # the now-empty directory it leaves behind. "Zero bytes land" means the directory holds no
      # book, not that mkdir_p's own side effect vanishes too.
      assert not File.exists?(dest_dir) or File.ls!(dest_dir) == []
      assert Repo.all(BookFile) == []
      assert Repo.reload!(target).status == :monitored
    end
  end

  describe "atomic partial-failure — replace" do
    setup ctx do
      %{target: target, audiobooks: audiobooks, release_dir: first_dir} =
        downloading(
          ctx,
          %{
            "01 - Track.mp3" => mp3_bytes("original-1"),
            "02 - Track.mp3" => mp3_bytes("original-2"),
            "03 - Track.mp3" => mp3_bytes("original-3")
          },
          "remote-1",
          barrier: true
        )

      complete_download(first_dir)
      poll!()

      assert Repo.reload!(target).status == :available
      %{target: target, audiobooks: audiobooks}
    end

    test "a fault mid-replace leaves the ORIGINAL N files byte-identical, not half-landed", %{
      target: target,
      audiobooks: audiobooks,
      tmp_dir: tmp
    } do
      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])

      original =
        for name <- ~w(01 02 03),
            do: {name, File.read!(Path.join(dir, "#{name} - The Dispossessed.mp3"))}

      new_release_dir = Path.join(tmp, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), mp3_bytes("replacement-1"))
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), mp3_bytes("replacement-2"))
      File.write!(Path.join(new_release_dir, "03 - Track.mp3"), mp3_bytes("replacement-3"))

      {:ok, _replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: Path.join(new_release_dir, "03 - Track.mp3"),
        reason: :eio
      })

      complete_download(new_release_dir, "remote-2")
      capture_log(fn -> poll!() end)

      for {name, bytes} <- original do
        assert File.read!(Path.join(dir, "#{name} - The Dispossessed.mp3")) == bytes
      end

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 3

      reloaded = Repo.reload!(target)
      assert reloaded.status == :available
    end

    # The direct regression test for the defect an earlier draft of the B7b plan did not catch:
    # a same-track-count replace whose new release resolves to the IDENTICAL ordered path set as
    # the target's current files must land the NEW bytes at every path, not silently keep the old
    # ones while reporting success.
    test "a same-track-count replace actually replaces bytes at every reused path", %{
      target: target,
      audiobooks: audiobooks,
      tmp_dir: tmp
    } do
      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])

      new_release_dir = Path.join(tmp, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), mp3_bytes("replacement-1"))
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), mp3_bytes("replacement-2"))
      File.write!(Path.join(new_release_dir, "03 - Track.mp3"), mp3_bytes("replacement-3"))

      {:ok, _replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      complete_download(new_release_dir, "remote-2")
      poll!()

      assert File.read!(Path.join(dir, "01 - The Dispossessed.mp3")) == mp3_bytes("replacement-1")
      assert File.read!(Path.join(dir, "02 - The Dispossessed.mp3")) == mp3_bytes("replacement-2")
      assert File.read!(Path.join(dir, "03 - The Dispossessed.mp3")) == mp3_bytes("replacement-3")

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 3
      assert Repo.reload!(target).status == :available
    end
  end

  # #501: `record_import_set/3`'s same-track-count replay-detection treats an identical
  # destination PATH SET as proof nothing changed, but audiobook destinations depend only on
  # work/disc/order (`AudiobookNaming.track_dest/4`) — never on source bytes. A confirmed
  # replacement whose new release resolves to the SAME track/disc layout reuses every path while
  # every track's actual audio (and therefore its size, duration, etc.) changes underneath it.
  # The "actually replaces bytes at every reused path" test above already proves the FILE
  # content lands correctly; these prove the `book_files` ROW is refreshed to match it.
  describe "same-path replacement metadata" do
    test "a same-track-count replace refreshes every persisted field to match the new audio",
         ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(ctx, %{
          "01 - Track.mp3" => mp3_bytes("original track one padding"),
          "02 - Track.mp3" => mp3_bytes("original track two, with rather more padding than one")
        })

      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      one = Path.join(release_dir, "01 - Track.mp3")
      two = Path.join(release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^one -> {:ok, probe(track_tag: 1, duration_seconds: 60)}
        ^two -> {:ok, probe(track_tag: 2, duration_seconds: 120)}
      end)

      complete_download(release_dir)
      poll!()

      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])
      dest_one = Path.join(dir, "01 - The Dispossessed.mp3")
      dest_two = Path.join(dir, "02 - The Dispossessed.mp3")

      original_one_bytes = mp3_bytes("original track one padding")
      original_two_bytes = mp3_bytes("original track two, with rather more padding than one")

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
      by_track = Map.new(files, &{&1.track_number, &1})
      assert by_track[1].size == byte_size(original_one_bytes)
      assert by_track[1].duration_seconds == 60
      assert by_track[2].size == byte_size(original_two_bytes)
      assert by_track[2].duration_seconds == 120

      new_release_dir = Path.join(ctx.tmp_dir, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      new_one_bytes = mp3_bytes("replacement one")
      new_two_bytes = mp3_bytes("a much longer replacement payload for track two entirely")
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), new_one_bytes)
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), new_two_bytes)

      new_one = Path.join(new_release_dir, "01 - Track.mp3")
      new_two = Path.join(new_release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^new_one -> {:ok, probe(track_tag: 1, duration_seconds: 90)}
        ^new_two -> {:ok, probe(track_tag: 2, duration_seconds: 150)}
      end)

      {:ok, _replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      complete_download(new_release_dir, "remote-2")
      poll!()

      assert File.read!(dest_one) == new_one_bytes
      assert File.read!(dest_two) == new_two_bytes

      reloaded = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(reloaded) == 2
      by_track2 = Map.new(reloaded, &{&1.track_number, &1})
      assert by_track2[1].size == byte_size(new_one_bytes)
      assert by_track2[1].duration_seconds == 90
      refute by_track2[1].size == byte_size(original_one_bytes)
      assert by_track2[2].size == byte_size(new_two_bytes)
      assert by_track2[2].duration_seconds == 150
      refute by_track2[2].size == byte_size(original_two_bytes)
      assert Repo.reload!(target).status == :available
      assert Repo.all(BookGrab) == []
    end

    test "replaying a same-track-count replace is a true no-op — rows stay on the replaced audio",
         ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(ctx, %{
          "01 - Track.mp3" => mp3_bytes("original-1"),
          "02 - Track.mp3" => mp3_bytes("original-2")
        })

      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      one = Path.join(release_dir, "01 - Track.mp3")
      two = Path.join(release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^one -> {:ok, probe(track_tag: 1)}
        ^two -> {:ok, probe(track_tag: 2)}
      end)

      complete_download(release_dir)
      poll!()

      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])
      dest_one = Path.join(dir, "01 - The Dispossessed.mp3")
      dest_two = Path.join(dir, "02 - The Dispossessed.mp3")

      new_release_dir = Path.join(ctx.tmp_dir, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      new_one_bytes = mp3_bytes("replacement one, quite a bit longer than the original was")
      new_two_bytes = mp3_bytes("replacement two")
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), new_one_bytes)
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), new_two_bytes)

      new_one = Path.join(new_release_dir, "01 - Track.mp3")
      new_two = Path.join(new_release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^new_one -> {:ok, probe(track_tag: 1)}
        ^new_two -> {:ok, probe(track_tag: 2)}
      end)

      {:ok, replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      complete_download(new_release_dir, "remote-2")
      poll!()

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
      by_track = Map.new(files, &{&1.track_number, &1})
      ids = Map.new(by_track, fn {track, file} -> {track, file.id} end)
      assert by_track[1].size == byte_size(new_one_bytes)
      assert by_track[2].size == byte_size(new_two_bytes)
      assert File.read!(dest_one) == new_one_bytes
      assert File.read!(dest_two) == new_two_bytes

      # Simulate the crash-and-retry: the same remote download is re-grabbed (a fresh grab row,
      # since the first was already deleted post-commit) with the same content, exactly as a
      # replayed import tick would re-derive it.
      {:ok, _replayed} =
        Books.Grabs.create(
          target.id,
          replace_grab.download_id,
          :torrent,
          replace_grab.release_title,
          replace: true
        )

      complete_download(new_release_dir, "remote-2")
      poll!()

      replayed = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(replayed) == 2
      by_track2 = Map.new(replayed, &{&1.track_number, &1})
      assert by_track2[1].id == ids[1]
      assert by_track2[2].id == ids[2]
      assert by_track2[1].size == byte_size(new_one_bytes)
      assert by_track2[2].size == byte_size(new_two_bytes)
      assert File.read!(dest_one) == new_one_bytes
      assert File.read!(dest_two) == new_two_bytes
      assert Repo.all(BookGrab) == []
    end

    test "an injected catalog failure during a same-track-count replace restores the original bytes and metadata",
         ctx do
      %{target: target, audiobooks: audiobooks, release_dir: release_dir} =
        downloading(ctx, %{
          "01 - Track.mp3" => mp3_bytes("original-1"),
          "02 - Track.mp3" => mp3_bytes("original-2")
        })

      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      one = Path.join(release_dir, "01 - Track.mp3")
      two = Path.join(release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^one -> {:ok, probe(track_tag: 1)}
        ^two -> {:ok, probe(track_tag: 2)}
      end)

      complete_download(release_dir)
      poll!()

      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])
      dest_one = Path.join(dir, "01 - The Dispossessed.mp3")
      dest_two = Path.join(dir, "02 - The Dispossessed.mp3")
      original_one_bytes = mp3_bytes("original-1")
      original_two_bytes = mp3_bytes("original-2")

      original = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      original_by_track = Map.new(original, &{&1.track_number, &1})

      new_release_dir = Path.join(ctx.tmp_dir, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), mp3_bytes("must never land 1"))
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), mp3_bytes("must never land 2"))

      new_one = Path.join(new_release_dir, "01 - Track.mp3")
      new_two = Path.join(new_release_dir, "02 - Track.mp3")

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^new_one -> {:ok, probe(track_tag: 1)}
        ^new_two -> {:ok, probe(track_tag: 2)}
      end)

      {:ok, _replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      # Simulate a concurrent operator hold landing between the download completing and this
      # tick's catalog write: `Files.record_import_set/3`'s `arm_target/1` guard refuses any
      # status outside `[:monitored, :available]`, so the whole transaction (every staged
      # backup-swap included) must roll all the way back to the pre-replace files.
      Repo.update_all(from(t in Cinder.Books.BookTarget, where: t.id == ^target.id),
        set: [status: :held, hold_reason: "operator hold"]
      )

      complete_download(new_release_dir, "remote-2")
      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).status == :held
      assert File.read!(dest_one) == original_one_bytes
      assert File.read!(dest_two) == original_two_bytes

      reloaded = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(reloaded) == 2
      by_track = Map.new(reloaded, &{&1.track_number, &1})
      assert by_track[1].id == original_by_track[1].id
      assert by_track[1].size == byte_size(original_one_bytes)
      assert by_track[2].id == original_by_track[2].id
      assert by_track[2].size == byte_size(original_two_bytes)
    end
  end

  describe "crash-safety around the record/stage-commit boundary" do
    # A fault injected on the commit-phase filesystem call (backup cleanup) after the catalog
    # transaction has already committed must never lose or roll back a `book_files` row or its
    # underlying file — `AudiobookImport.commit/4`'s own "logged, not retried" contract,
    # generalized to N stage tokens. A later `Library.reconcile_stages/0` sweep converges.
    test "a commit-phase failure after the DB commit leaves every row and every file intact",
         ctx do
      %{target: target, audiobooks: audiobooks, release_dir: first_dir} =
        downloading(
          ctx,
          %{
            "01 - Track.mp3" => mp3_bytes("original-1"),
            "02 - Track.mp3" => mp3_bytes("original-2")
          },
          "remote-1",
          barrier: true
        )

      complete_download(first_dir)
      poll!()
      assert Repo.reload!(target).status == :available

      new_release_dir = Path.join(ctx.tmp_dir, "downloads/release-remote-2")
      File.mkdir_p!(new_release_dir)
      File.write!(Path.join(new_release_dir, "01 - Track.mp3"), mp3_bytes("replacement-1"))
      File.write!(Path.join(new_release_dir, "02 - Track.mp3"), mp3_bytes("replacement-2"))

      {:ok, _replace_grab} =
        Books.Grabs.create(target.id, "remote-2", :torrent, "The Dispossessed Retail",
          replace: true
        )

      # Fires during the post-commit `StageEngine.commit/1` loop, not during staging: every
      # `.cinder-rollback-*` backup removal fails, simulating the process dying (or the backup
      # cleanup erroring) between the catalog write's commit and the journal finishing its own
      # bookkeeping.
      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :rm,
        source_contains: ".cinder-rollback-",
        reason: :eio
      })

      complete_download(new_release_dir, "remote-2")
      capture_log(fn -> poll!() end)

      dir = Path.join([audiobooks, "Ursula K. Le Guin", "The Dispossessed"])
      assert File.read!(Path.join(dir, "01 - The Dispossessed.mp3")) == mp3_bytes("replacement-1")
      assert File.read!(Path.join(dir, "02 - The Dispossessed.mp3")) == mp3_bytes("replacement-2")

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
      assert Repo.reload!(target).status == :available

      # Clear the injected failure and let the next sweep converge the still-`:committed` journal
      # rows without deleting any of the N files.
      Application.delete_env(:cinder, :filesystem_failure)
      assert :ok = Library.reconcile_stages()
      assert Library.quarantined_import_stages() == []
      assert File.read!(Path.join(dir, "01 - The Dispossessed.mp3")) == mp3_bytes("replacement-1")
      assert File.read!(Path.join(dir, "02 - The Dispossessed.mp3")) == mp3_bytes("replacement-2")
    end
  end

  # --- fixtures ---

  defp poll! do
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()
    stop_supervised!(BookPoller)
  end

  defp complete_download(release_dir, remote_id \\ "remote-1") do
    expect(Cinder.Download.ClientMock, :status, fn ^remote_id ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)
  end

  defp downloading(ctx, files, remote_id \\ "remote-1", fixture_opts \\ [])

  defp downloading(%{tmp_dir: tmp} = ctx, files, remote_id, fixture_opts) do
    build_target(real_audiobook_library(tmp, fixture_opts), ctx, files, remote_id)
  end

  defp build_target(%{downloads: downloads, audiobooks: audiobooks}, _ctx, files, remote_id) do
    release_dir = Path.join(downloads, "release-#{remote_id}")
    File.mkdir_p!(release_dir)

    Enum.each(files, fn {relative_name, content} ->
      path = Path.join(release_dir, relative_name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    profile = audiobook_profile(audiobooks)
    work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
    {:ok, target} = Books.monitor_target(work, :audiobook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, remote_id, :torrent, "The Dispossessed Audiobook")

    %{
      grab: grab,
      target: target,
      work: work,
      audiobooks: audiobooks,
      downloads: downloads,
      release_dir: release_dir
    }
  end

  defp audiobook_profile(audiobooks) do
    case Enum.find(Catalog.list_profiles(:audiobook), &(&1.library_path == audiobooks)) do
      %Catalog.Profile{} = existing ->
        existing

      nil ->
        {:ok, profile} =
          Catalog.create_profile(%{
            name: "Audiobooks #{System.unique_integer([:positive])}",
            kind: :audiobook,
            handling: :standard,
            library_path: audiobooks
          })

        profile
    end
  end

  defp probe(overrides) do
    Map.merge(
      %{
        container: :mp3,
        duration_seconds: nil,
        chapter_count: nil,
        track_tag: nil,
        disc_tag: nil,
        album_tag: nil,
        title_tag: nil
      },
      Map.new(overrides)
    )
  end

  defp mp3_bytes(suffix \\ ""), do: "ID3" <> <<3, 0, 0, 0, 0, 0, 0, 0, 0>> <> suffix
  defp m4b_bytes, do: <<0, 0, 0, 32>> <> "ftyp" <> "M4B "

  defp real_audiobook_library(tmp, fixture_opts) do
    downloads = Path.join(tmp, "downloads")
    audiobooks = Path.join(tmp, "audiobooks")
    File.mkdir_p!(downloads)
    File.mkdir_p!(audiobooks)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :audiobooks_library_path,
      :move_on_import,
      :audio_probe
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    filesystem =
      if Keyword.get(fixture_opts, :barrier, false),
        do: Cinder.Test.BarrierFilesystem,
        else: Cinder.Library.Filesystem.Disk

    Application.put_env(:cinder, :filesystem, filesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :audiobooks_library_path, audiobooks)
    Application.put_env(:cinder, :move_on_import, false)
    Application.put_env(:cinder, :audio_probe, nil)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)

      Application.delete_env(:cinder, :filesystem_failure)
      Application.delete_env(:cinder, :filesystem_failures)
    end)

    %{downloads: downloads, audiobooks: audiobooks}
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
