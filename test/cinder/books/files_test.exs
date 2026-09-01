defmodule Cinder.Books.FilesTest do
  @moduledoc """
  `record_import/3`'s `replace:` path — the plan's own blocker: a naive unconditional
  `Repo.delete_all` before every replace-flagged insert would delete the household's only copy of
  a book on a replayed import. These tests defend the replay-safe `maybe_supersede/3` fix.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookTarget}
  alias Cinder.Catalog

  setup do
    id = unique_id()

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Beloved #{id}",
        identifier: identifier(id)
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)

    %{target: target}
  end

  describe "record_import/3 without replace" do
    test "a fresh import returns {:ok, file} and arms the target", %{target: target} do
      assert {:ok, %BookFile{path: path}} =
               Books.Files.record_import(target, %{
                 path: "/tmp/book-#{target.id}-a.epub",
                 size: 1000,
                 format: :epub
               })

      assert path == "/tmp/book-#{target.id}-a.epub"
      assert %BookTarget{status: :available} = Books.get_target(target.id)
    end
  end

  describe "record_import/3 with replace: true" do
    test "a first replace on an available target with an existing file deletes the old row and
          inserts exactly one new row",
         %{target: target} do
      old_path = "/tmp/book-#{target.id}-old.epub"
      new_path = "/tmp/book-#{target.id}-new.epub"

      assert {:ok, _old_file} =
               Books.Files.record_import(target, %{path: old_path, size: 1000, format: :epub})

      assert {:ok, new_file, superseded_paths} =
               Books.Files.record_import(
                 target,
                 %{path: new_path, size: 2000, format: :epub},
                 replace: true
               )

      assert new_file.path == new_path
      assert superseded_paths == [old_path]

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert [%BookFile{path: ^new_path}] = files

      reloaded = Books.get_target(target.id)
      assert reloaded.status == :available
    end

    # The property that would fail against the plan's first draft: an unconditional
    # `Repo.delete_all` before every replace-flagged insert deletes the target's CURRENT, correct
    # file on a replay, because by the second call it is the only row present. Replaying the same
    # replace import twice in a row (simulating a crash between commit and grab deletion) must be
    # a true no-op the second time: exactly one `book_files` row, same path, and nothing reported
    # as superseded so the post-commit unlink step deletes nothing.
    test "replaying an already-committed replace import is a true no-op", %{target: target} do
      old_path = "/tmp/book-#{target.id}-old.epub"
      new_path = "/tmp/book-#{target.id}-new.epub"

      assert {:ok, _old_file} =
               Books.Files.record_import(target, %{path: old_path, size: 1000, format: :epub})

      attrs = %{path: new_path, size: 2000, format: :epub}

      # Attempt 1: the genuine replace. old_path is superseded.
      assert {:ok, first_file, [^old_path]} =
               Books.Files.record_import(target, attrs, replace: true)

      # Attempt 2: the replay, with IDENTICAL attrs — exactly what a crashed-and-retried import
      # tick produces (BookNaming computes the same destination path deterministically).
      assert {:ok, second_file, []} = Books.Files.record_import(target, attrs, replace: true)

      assert second_file.id == first_file.id
      assert second_file.path == new_path

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert [%BookFile{path: ^new_path, id: id}] = files
      assert id == first_file.id
    end

    test "a replace grab that fails on its first attempt leaves the original file untouched", %{
      target: target
    } do
      old_path = "/tmp/book-#{target.id}-old.epub"

      assert {:ok, _old_file} =
               Books.Files.record_import(target, %{path: old_path, size: 1000, format: :epub})

      # Directly park the target `:held` — simulating an operator's decision that landed between
      # the download completing and this import running — so `arm_target/1`'s guard (which only
      # accepts `:monitored`/`:available`) fails AFTER `maybe_supersede/3` already ran inside the
      # same transaction: the whole thing must roll back together.
      Repo.update_all(from(t in BookTarget, where: t.id == ^target.id),
        set: [status: :held, hold_reason: "operator hold"]
      )

      assert {:error, :stale_status} =
               Books.Files.record_import(
                 target,
                 %{path: "/tmp/book-#{target.id}-new.epub", size: 2000, format: :epub},
                 replace: true
               )

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert [%BookFile{path: ^old_path}] = files
    end
  end

  defp identifier(id), do: %{provider: "openlibrary", kind: "work", foreign_id: id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
