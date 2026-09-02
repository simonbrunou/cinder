defmodule Cinder.Books.AudiobookshelfScanTest do
  @moduledoc """
  `Cinder.Books.list_pending_audiobook_scans/0` and `mark_audiobookshelf_scanned/1` — the
  context-level query and write `Cinder.Download.BookPoller`'s retryable scan phase (B7c) reads
  and writes. `Cinder.Books.Files.arm_target/1`'s reset of the flag on a fresh `:available`
  transition is covered in `Cinder.Books.FilesTest`.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.BookTarget

  test "an :available audiobook target with no scan timestamp is pending" do
    target = audiobook_target() |> force_available()

    assert Books.list_pending_audiobook_scans() == [target]
  end

  test "an :available audiobook target that was already scanned is not pending" do
    target = audiobook_target() |> force_available()
    :ok = Books.mark_audiobookshelf_scanned(target.id)

    assert Books.list_pending_audiobook_scans() == []
  end

  test "a :monitored (not yet available) audiobook target is never pending" do
    audiobook_target()
    assert Books.list_pending_audiobook_scans() == []
  end

  test "an :available e-book target is never pending, regardless of its scan timestamp" do
    ebook_target() |> force_available()
    assert Books.list_pending_audiobook_scans() == []
  end

  test "mark_audiobookshelf_scanned/1 stamps only the target it names" do
    stamped = audiobook_target() |> force_available()
    other = audiobook_target() |> force_available()

    :ok = Books.mark_audiobookshelf_scanned(stamped.id)

    assert %DateTime{} = Repo.reload!(stamped).audiobookshelf_scanned_at
    assert Repo.reload!(other).audiobookshelf_scanned_at == nil
  end

  test "mark_audiobookshelf_scanned/1 broadcasts nothing — no side effect beyond the write" do
    target = audiobook_target() |> force_available()
    Books.subscribe_targets()

    :ok = Books.mark_audiobookshelf_scanned(target.id)

    refute_receive _any, 50
  end

  defp force_available(%BookTarget{id: id} = target) do
    Repo.update_all(from(t in BookTarget, where: t.id == ^id), set: [status: :available])
    Repo.reload!(target)
  end

  defp audiobook_target, do: target(:audiobook)
  defp ebook_target, do: target(:ebook)

  defp target(media_kind) do
    id = unique_id()

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{
        name: "#{media_kind} #{id}",
        kind: media_kind,
        handling: :standard
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, media_kind, profile)
    target
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
