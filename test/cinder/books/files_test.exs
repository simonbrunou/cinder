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

    # SS7c review: an untested correctness property is worse when a doc comment elsewhere claims
    # it's covered. Proves `arm_target/1`'s `if media_kind == :audiobook` guard genuinely gates on
    # media_kind rather than merely happening to see the column already `nil` — the column starts
    # `nil` for a fresh e-book target, but is set here directly to prove a replace never touches
    # it even when it is NOT already `nil` (production code never sets it for `:ebook`, but the
    # guard itself, not that fact, is what this test defends).
    test "a replace on an e-book target never touches audiobookshelf_scanned_at, even if
          somehow set",
         %{target: target} do
      stamp = DateTime.utc_now(:second)

      Repo.update_all(from(t in BookTarget, where: t.id == ^target.id),
        set: [audiobookshelf_scanned_at: stamp]
      )

      old_path = "/tmp/book-#{target.id}-old.epub"
      new_path = "/tmp/book-#{target.id}-new.epub"

      assert {:ok, _old_file} =
               Books.Files.record_import(target, %{path: old_path, size: 1000, format: :epub})

      assert {:ok, _new_file, _superseded} =
               Books.Files.record_import(
                 target,
                 %{path: new_path, size: 2000, format: :epub},
                 replace: true
               )

      assert Repo.reload!(target).audiobookshelf_scanned_at == stamp
    end
  end

  describe "record_import_set/3 — multi-track audiobook import" do
    setup do
      id = unique_id()

      {:ok, profile} =
        Catalog.create_profile(%{name: "Audiobooks #{id}", kind: :audiobook, handling: :standard})

      {:ok, work} = Books.upsert_work(%{title: "Beloved audio #{id}", identifier: identifier(id)})
      {:ok, target} = Books.monitor_target(work, :audiobook, profile)

      %{target: target}
    end

    test "a fresh import returns {:ok, files} for every track and arms the target", %{
      target: target
    } do
      attrs = [
        %{path: "/tmp/ab-#{target.id}-01.mp3", size: 1000, format: :mp3, track_number: 1},
        %{path: "/tmp/ab-#{target.id}-02.mp3", size: 1000, format: :mp3, track_number: 2}
      ]

      assert {:ok, files} = Books.Files.record_import_set(target, attrs)
      assert length(files) == 2
      assert %BookTarget{status: :available} = Books.get_target(target.id)
    end

    # Identical incoming/existing path sets → zero rows deleted, superseded_paths: [].
    test "identical incoming and existing path sets delete nothing and supersede nothing", %{
      target: target
    } do
      attrs = [
        %{path: "/tmp/ab-#{target.id}-01.mp3", size: 1000, format: :mp3},
        %{path: "/tmp/ab-#{target.id}-02.mp3", size: 1000, format: :mp3}
      ]

      assert {:ok, [first, second]} = Books.Files.record_import_set(target, attrs)

      assert {:ok, [replayed_first, replayed_second], []} =
               Books.Files.record_import_set(target, attrs, replace: true)

      assert Enum.map([replayed_first, replayed_second], & &1.id) ==
               Enum.map([first, second], & &1.id)

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert length(files) == 2
    end

    # Disjoint sets (different track count, no path shared) → every existing row deleted, every
    # one of their paths in superseded_paths.
    test "a fully disjoint incoming set deletes every existing row and supersedes every path", %{
      target: target
    } do
      old_attrs = [
        %{path: "/tmp/ab-#{target.id}-old-01.mp3", size: 1000, format: :mp3},
        %{path: "/tmp/ab-#{target.id}-old-02.mp3", size: 1000, format: :mp3}
      ]

      assert {:ok, _old_files} = Books.Files.record_import_set(target, old_attrs)

      new_attrs = [
        %{path: "/tmp/ab-#{target.id}-new-01.m4b", size: 5000, format: :m4b}
      ]

      assert {:ok, [new_file], superseded} =
               Books.Files.record_import_set(target, new_attrs, replace: true)

      assert new_file.path == "/tmp/ab-#{target.id}-new-01.m4b"

      assert Enum.sort(superseded) ==
               Enum.sort(Enum.map(old_attrs, & &1.path))

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      new_path = new_file.path
      assert [%BookFile{path: ^new_path}] = files
    end

    # Partial overlap (some tracks reused, some old tracks orphaned) → every existing row
    # deleted, including the reused-path one, but superseded_paths contains only the orphaned
    # path — never a path this same import just landed new bytes at.
    test "a partial-overlap incoming set deletes every existing row but supersedes only the orphan",
         %{target: target} do
      reused_path = "/tmp/ab-#{target.id}-track.mp3"
      orphan_path = "/tmp/ab-#{target.id}-old-02.mp3"

      old_attrs = [
        %{path: reused_path, size: 1000, format: :mp3},
        %{path: orphan_path, size: 1000, format: :mp3}
      ]

      assert {:ok, _old_files} = Books.Files.record_import_set(target, old_attrs)

      # The new release reuses the first track's destination path (deterministic naming landed
      # new bytes there via the staging layer's backup-swap) and drops the second track entirely.
      new_attrs = [%{path: reused_path, size: 9999, format: :mp3}]

      assert {:ok, [reused_file], [^orphan_path]} =
               Books.Files.record_import_set(target, new_attrs, replace: true)

      assert reused_file.path == reused_path
      assert reused_file.size == 9999

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert [%BookFile{path: ^reused_path, size: 9999}] = files
    end

    # The incoming set a strict subset of the existing one (fewer tracks in the new release) →
    # every existing row deleted, the paths absent from the incoming set are in superseded_paths.
    test "an incoming subset of the existing set supersedes the dropped tracks", %{
      target: target
    } do
      kept_path = "/tmp/ab-#{target.id}-01.mp3"
      dropped_path = "/tmp/ab-#{target.id}-02.mp3"

      old_attrs = [
        %{path: kept_path, size: 1000, format: :mp3},
        %{path: dropped_path, size: 1000, format: :mp3}
      ]

      assert {:ok, _old_files} = Books.Files.record_import_set(target, old_attrs)

      new_attrs = [%{path: kept_path, size: 1000, format: :mp3}]

      assert {:ok, [kept_file], [^dropped_path]} =
               Books.Files.record_import_set(target, new_attrs, replace: true)

      assert kept_file.path == kept_path

      files = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)
      assert [%BookFile{path: ^kept_path}] = files
    end

    test "a mid-set insert failure rolls the whole transaction back", %{target: target} do
      conflicting_path = "/tmp/ab-conflict-#{target.id}.mp3"

      {:ok, other_profile} =
        Catalog.create_profile(%{
          name: "Other audiobooks #{unique_id()}",
          kind: :audiobook,
          handling: :standard
        })

      {:ok, other_work} =
        Books.upsert_work(%{
          title: "Another work #{unique_id()}",
          identifier: identifier(unique_id())
        })

      {:ok, other_target} = Books.monitor_target(other_work, :audiobook, other_profile)

      assert {:ok, _claimed} =
               Books.Files.record_import_set(other_target, [
                 %{path: conflicting_path, size: 1000, format: :mp3}
               ])

      attrs = [
        %{path: "/tmp/ab-#{target.id}-01.mp3", size: 1000, format: :mp3},
        %{path: conflicting_path, size: 1000, format: :mp3}
      ]

      assert {:error, :book_file_exists} = Books.Files.record_import_set(target, attrs)
      assert Repo.all(from f in BookFile, where: f.book_target_id == ^target.id) == []
      assert Books.get_target(target.id).status == :monitored
    end

    # The B7c property that matters most: a replace's new content must be re-told to
    # Audiobookshelf, not silently skipped because an EARLIER import of this same target was
    # already scanned. `arm_target/1` resets the flag on every `:available`-transition, fresh or
    # replace, for `:audiobook` targets only.
    test "a replace resets audiobookshelf_scanned_at to nil, telling the poller to re-scan", %{
      target: target
    } do
      old_attrs = [%{path: "/tmp/ab-#{target.id}-01.mp3", size: 1000, format: :mp3}]
      assert {:ok, _files} = Books.Files.record_import_set(target, old_attrs)

      :ok = Books.mark_audiobookshelf_scanned(target.id)
      assert %DateTime{} = Repo.reload!(target).audiobookshelf_scanned_at

      new_attrs = [%{path: "/tmp/ab-#{target.id}-02.m4b", size: 5000, format: :m4b}]

      assert {:ok, _new_files, _superseded} =
               Books.Files.record_import_set(target, new_attrs, replace: true)

      assert Repo.reload!(target).audiobookshelf_scanned_at == nil
    end

    # Codex review on PR #569: `AudiobookSources`' own AudioProbe can time out or exhaust its
    # probe budget on ANY given tick and degrade gracefully to nil duration/track/disc facts,
    # independent of whether the underlying bytes changed. `attrs[:changed?]` (populated from
    # `StageEngine`'s own `placed?` staging outcome, NOT from `replace?`) is what must gate the
    # metadata refresh: a same-inode replay (`changed?: false`) must never let a degraded probe
    # attempt overwrite metadata an earlier, successful tick already committed.
    test "a degraded replay never overwrites metadata from an earlier successful probe", %{
      target: target
    } do
      path = "/tmp/ab-#{target.id}-01.mp3"

      good_attrs = [
        %{path: path, size: 1000, format: :mp3, track_number: 1, duration_seconds: 60}
      ]

      assert {:ok, [file]} = Books.Files.record_import_set(target, good_attrs)
      assert file.duration_seconds == 60
      assert file.track_number == 1

      degraded_attrs = [
        %{
          path: path,
          size: 1000,
          format: :mp3,
          track_number: nil,
          duration_seconds: nil,
          changed?: false
        }
      ]

      assert {:ok, [replayed], []} =
               Books.Files.record_import_set(target, degraded_attrs, replace: true)

      assert replayed.id == file.id
      assert replayed.duration_seconds == 60
      assert replayed.track_number == 1

      reloaded = Repo.get!(BookFile, file.id)
      assert reloaded.duration_seconds == 60
      assert reloaded.track_number == 1
    end
  end

  defp identifier(id), do: %{provider: "openlibrary", kind: "work", foreign_id: id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
