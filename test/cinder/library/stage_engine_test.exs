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

      assert {:error, _reason} = StageEngine.stage_book_place(source, dest, books, replace: true)

      # The half-prepared stage's own rollback (via `Library.reconcile_stages/0`) restores the
      # original destination bytes from its tracked backup path.
      Application.delete_env(:cinder, :filesystem_failure)
      assert :ok = Cinder.Library.reconcile_stages()
      assert File.read!(dest) == "old bytes"
      assert Cinder.Library.quarantined_import_stages() == []
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
