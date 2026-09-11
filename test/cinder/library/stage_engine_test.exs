defmodule Cinder.Library.StageEngineTest do
  @moduledoc """
  `stage_book_place/4`'s `:replace` path — the fix for the false safety claim the B7b plan names
  explicitly: a destination collision used to always keep the existing file, even when the caller
  had just confirmed a "Find a better match" replace. These tests defend the real,
  backup-then-atomic-swap replacement and its rollback, and that `:extensions` genuinely widens
  what this ONE staging function accepts (the audiobook call site's own gate) without touching the
  e-book default.

  Real filesystem and the real `PathPolicy`/`ImportStage` throughout — the guarantee under test is
  what actually lands on disk and what a rollback actually restores.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Library.{ImportStage, StageEngine}
  alias Cinder.Test.BarrierFilesystem

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    books = Path.join(tmp, "books")
    File.mkdir_p!(downloads)
    File.mkdir_p!(books)

    keys = [:filesystem, :path_policy, :import_roots, :explicit_import_roots]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)

      Application.delete_env(:cinder, :filesystem_failure)
    end)

    {:ok, downloads: downloads, books: books}
  end

  @moduletag :tmp_dir

  describe "replace: false (default) — byte-for-byte unchanged from stage_book_place/3" do
    test "a fresh destination is staged", %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "original")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))

      assert {:ok, rollback, true} = StageEngine.stage_book_place(source, dest, books)
      assert File.read!(dest) == "original"
      assert :ok = commit!(rollback)
    end

    test "an existing destination is kept, not overwritten", %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "new bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "operator's own copy")

      assert {:ok, rollback, false} = StageEngine.stage_book_place(source, dest, books)
      assert File.read!(dest) == "operator's own copy"
      assert :ok = commit!(rollback)
    end
  end

  describe "replace: true" do
    test "a fresh destination is staged exactly as a non-replace import", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "original")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))

      assert {:ok, rollback, true} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "original"
      assert :ok = commit!(rollback)
    end

    # The direct regression test for the false safety claim: a same-track-count replace whose
    # destination already holds a DIFFERENT file must actually swap the bytes, not silently keep
    # the old ones and report success.
    test "a genuinely different existing file is really replaced — the defect's regression test",
         %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book (retail).epub")
      File.write!(source, "new retail bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "old bytes")

      assert {:ok, rollback, true} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "new retail bytes"
      assert :ok = commit!(rollback)
    end

    test "a same-inode collision (already-completed replace, replayed) is an idempotent no-op", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.ln!(source, dest)

      assert {:ok, rollback, false} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "bytes"
      assert :ok = commit!(rollback)
    end

    # The OLD file is moved to a tracked backup path, never deleted outright — so a failure
    # partway through the swap can restore it exactly. Proven here by injecting a failure AFTER
    # the backup move (`land_candidate/2`'s `ln`) and confirming rollback restores the original
    # bytes rather than leaving the destination empty or half-swapped.
    test "a failure after the backup move rolls back to the ORIGINAL bytes, not an empty dest", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book (retail).epub")
      File.write!(source, "new retail bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "old bytes")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: ".cinder-stage-",
        reason: :eio
      })

      assert {:error, :eio} = StageEngine.stage_book_place(source, dest, books, replace: true)

      # Pin the post-failure state, not just the rollback's outcome: `File.read!(dest)` below is
      # equally satisfied by a stage that failed BEFORE the backup move, with `dest` untouched and
      # nothing to restore — green while defending a path it never entered.
      refute File.exists?(dest)

      assert [_backup] =
               Path.wildcard(Path.join(Path.dirname(dest), ".cinder-rollback-*"), match_dot: true)

      # The half-prepared stage's own rollback (via `Library.reconcile_stages/0`) restores the
      # original destination bytes from its tracked backup path.
      Application.delete_env(:cinder, :filesystem_failure)
      assert :ok = Cinder.Library.reconcile_stages()
      assert File.read!(dest) == "old bytes"
      assert Cinder.Library.quarantined_import_stages() == []
    end

    # Issue #558: the journal's `{inode, device, size}` identity is captured at `dest` and then
    # checked at `.cinder-rollback-<key>`, either side of a rename this engine performs itself.
    # On a mount that computes the inode it reports from the path (mergerfs
    # `inodecalc=path-hash`), that comparison can never match, and BOTH halves of the two-phase
    # commit break for a file nothing else touched: a committed replace can't clean up its
    # backup, and an uncommitted one can't restore it. The operation-keyed path — which only this
    # journal row ever names — is the ownership evidence that survives.
    test "a committed replace still cleans up its backup when the mount rewrites inodes on rename",
         %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book (retail).epub")
      File.write!(source, "new retail bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "old bytes")
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, rollback, true} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "new retail bytes"
      assert :ok = commit!(rollback)

      # The replaced original is gone rather than stranded under its rollback name forever.
      assert Path.wildcard(Path.join(Path.dirname(dest), ".cinder-rollback-*"), match_dot: true) ==
               []

      assert Cinder.Library.quarantined_import_stages() == []
    end

    test "a rollback still restores the ORIGINAL bytes when the mount rewrites inodes on rename",
         %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book (retail).epub")
      File.write!(source, "new retail bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "old bytes")
      BarrierFilesystem.report_path_derived_inodes()

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: ".cinder-stage-",
        reason: :eio
      })

      assert {:error, :eio} = StageEngine.stage_book_place(source, dest, books, replace: true)

      # Without this the assertion below is also satisfied by a stage that failed BEFORE
      # `maybe_move_backup/2` ever moved anything — `dest` untouched, nothing to restore, and a
      # green test defending a path it never entered.
      refute File.exists?(dest)

      assert [_backup] =
               Path.wildcard(Path.join(Path.dirname(dest), ".cinder-rollback-*"), match_dot: true)

      Application.delete_env(:cinder, :filesystem_failure)
      assert :ok = Cinder.Library.reconcile_stages()
      assert File.read!(dest) == "old bytes"
      assert Cinder.Library.quarantined_import_stages() == []
    end
  end

  # Issue #584: the collision branch asks "is `dest` already this exact file?" by comparing what
  # `lstat` reports for two DIFFERENT paths, which on this mount class always reads "different".
  # A replay of an already-completed replace then re-runs the whole backup-then-swap over content
  # already swapped once and reports a fresh publication for bytes that never moved.
  #
  # The destination is a configured library root here because that is what makes the backing
  # identity reachable at all — `Filesystem.backing_identity/1` answers only for paths under a
  # configured library or import root, and in production every destination is one.
  describe "replace: true on a mount that reports path-derived inodes" do
    setup %{books: books} do
      saved = Application.get_env(:cinder, :books_library_path)
      Application.put_env(:cinder, :books_library_path, books)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:cinder, :books_library_path, saved),
          else: Application.delete_env(:cinder, :books_library_path)
      end)

      :ok
    end

    test "a replayed replace is still an idempotent no-op", %{downloads: downloads, books: books} do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.ln!(source, dest)
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, rollback, false} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "bytes"

      # `placed?: false` alone is also satisfied by a swap that happened and was reported as a
      # keep, so pin the absence of the backup a real swap would have left behind.
      assert Path.wildcard(Path.join(Path.dirname(dest), ".cinder-rollback-*"), match_dot: true) ==
               []

      assert :ok = commit!(rollback)
    end

    # The other half of the proof: it must not answer "same file" for two files that merely both
    # sit under a configured root, or a confirmed replace would silently keep the old bytes —
    # the exact defect `stage_book_place/4`'s `:replace` path exists to fix. The destination is
    # hardlinked from a SECOND download so it clears the link-count precondition and the proof
    # actually runs, rather than being short-circuited by a single-link destination.
    test "a genuinely different destination is still replaced", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book (retail).epub")
      File.write!(source, "new retail bytes")
      other = Path.join(downloads, "book (old).epub")
      File.write!(other, "old bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      File.ln!(other, dest)
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, rollback, true} =
               StageEngine.stage_book_place(source, dest, books, replace: true)

      assert File.read!(dest) == "new retail bytes"
      assert :ok = commit!(rollback)
      assert Cinder.Library.quarantined_import_stages() == []
    end
  end

  # Issue #588: `remove_or_preserve_destination/2` decided whether the file now at `dest` was the
  # one this stage landed there by comparing `lstat(dest)` against the journal's `staged_*`/
  # `candidate_*` triples, both captured at a DIFFERENT path (the candidate's) and both
  # `lstat`-derived. On this mount class that cross-path comparison can never match, so a fresh
  # placement's rollback could not recognise the file it had itself just landed.
  describe "a fresh placement rolled back on a mount that reports path-derived inodes" do
    setup %{books: books} do
      saved = Application.get_env(:cinder, :books_library_path)
      Application.put_env(:cinder, :books_library_path, books)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:cinder, :books_library_path, saved),
          else: Application.delete_env(:cinder, :books_library_path)
      end)

      :ok
    end

    # Pre-fix, this returned `{:error, :import_stage_destination_changed}`: `remove_or_preserve_destination/2`
    # could not recognise the file it had just landed at `dest`, quarantined the stage, and left
    # the file published — the stage row survived and the file stayed on disk. Post-fix the
    # `candidate_backing_identity` disjunct recognises the file (one backing file, two names —
    # candidate and `dest`, via the hardlink `land_candidate/2` makes) and the rollback actually
    # removes what it landed.
    test "the file it landed is deleted and its journal row is gone, not quarantined", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, rollback, true} = StageEngine.stage_book_place(source, dest, books)
      assert File.exists?(dest)

      assert :ok = StageEngine.rollback(rollback)

      refute File.exists?(dest)
      assert ImportStage.get(rollback.stage_id) == nil
      assert Cinder.Library.quarantined_import_stages() == []
    end

    # The other half of the proof: the new disjunct is positive evidence for the file THIS stage
    # landed, not a blanket "delete whatever occupies dest now". A third party's file swapped in
    # after placement is a genuinely different backing file (a fresh `File.rm!/1` +
    # `File.write!/2` gets a new real inode from the underlying filesystem, unaffected by the
    # path-hash mount model — `backing_identity/1` reads the backing store, not the union), so
    # the rollback must still refuse to touch it and still park the stage. The replacement bytes
    # are also a different LENGTH from the staged bytes on purpose: `landed_candidate?/2`'s size
    # guard exists precisely because a freed inode can be reused by the very next create on the
    # same backing device, and a same-length third-party file would leave that guard unexercised
    # even though the backing identity itself already happens to differ here.
    test "a third party's file at dest afterward is preserved and the stage still parks", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "book.epub")
      File.write!(source, "bytes")
      dest = Path.join(books, "Author/Title/book.epub")
      File.mkdir_p!(Path.dirname(dest))
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, rollback, true} = StageEngine.stage_book_place(source, dest, books)

      File.rm!(dest)
      File.write!(dest, "someone else's bytes")

      assert {:error, :import_stage_destination_changed} = StageEngine.rollback(rollback)
      assert File.read!(dest) == "someone else's bytes"
      assert [_stage] = Cinder.Library.quarantined_import_stages()
    end
  end

  describe ":extensions — the audiobook call site's own gate" do
    test "a .mp3 source is refused with the e-book default extensions", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "chapter.mp3")
      File.write!(source, "mp3 bytes")
      dest = Path.join(books, "Author/Title/chapter.mp3")
      File.mkdir_p!(Path.dirname(dest))

      assert {:error, :unsafe_source} = StageEngine.stage_book_place(source, dest, books)
    end

    test "a .mp3 source is accepted with an audiobook :extensions override", %{
      downloads: downloads,
      books: books
    } do
      source = Path.join(downloads, "chapter.mp3")
      File.write!(source, "mp3 bytes")
      dest = Path.join(books, "Author/Title/01 - Title.mp3")
      File.mkdir_p!(Path.dirname(dest))

      assert {:ok, rollback, true} =
               StageEngine.stage_book_place(source, dest, books, extensions: [".mp3", ".m4b"])

      assert File.read!(dest) == "mp3 bytes"
      assert :ok = commit!(rollback)
    end
  end

  # Marks the journal row `:committed` first, matching what `Cinder.Books.Files.record_import/3`
  # does inside its own transaction before ever calling `StageEngine.commit/1` — a bare
  # `StageEngine.commit/1` on a still-`:prepared` row is `{:error, :import_stage_not_committed}`
  # by design (the same guard against committing a stage nothing recorded).
  defp commit!(%{stage_id: id} = rollback) do
    ImportStage.mark_committed!([id])
    StageEngine.commit(rollback)
  end
end
