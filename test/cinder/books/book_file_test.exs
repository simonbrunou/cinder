defmodule Cinder.Books.BookFileTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books
  alias Cinder.Books.BookFile
  alias Cinder.Catalog

  setup do
    id = unique_id()

    {:ok, ebook_profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, audiobook_profile} =
      Catalog.create_profile(%{name: "Audiobooks #{id}", kind: :audiobook, handling: :standard})

    {:ok, work} = Books.upsert_work(%{title: "Beloved #{id}", identifier: identifier(id)})

    {:ok, ebook_target} = Books.monitor_target(work, :ebook, ebook_profile)
    {:ok, audiobook_target} = Books.monitor_target(work, :audiobook, audiobook_profile)

    %{ebook_target: ebook_target, audiobook_target: audiobook_target, id: id}
  end

  test "an m4b/mp3 format is accepted through the real changeset path, not just the DB CHECK", %{
    audiobook_target: target,
    id: id
  } do
    assert %Ecto.Changeset{valid?: true} =
             BookFile.changeset(%BookFile{}, %{
               book_target_id: target.id,
               path: "/tmp/book-#{id}.m4b",
               size: 500_000_000,
               format: :m4b
             })

    assert {:ok, %BookFile{format: :m4b}} =
             Books.Files.record_import(target, %{
               path: "/tmp/book-#{id}-a.m4b",
               size: 500_000_000,
               format: :m4b
             })
  end

  test "an unsupported format is rejected by the changeset's format cast, not accepted silently" do
    changeset =
      BookFile.changeset(%BookFile{}, %{
        book_target_id: 1,
        path: "/tmp/unsupported.zip",
        format: :zip
      })

    refute changeset.valid?
    assert %{format: ["is invalid"]} = errors_on(changeset)
  end

  test "narrator, duration, track, disc, and chapter count round-trip on an audiobook file", %{
    audiobook_target: target,
    id: id
  } do
    assert {:ok, file} =
             Books.Files.record_import(target, %{
               path: "/tmp/book-#{id}-b.m4b",
               size: 500_000_000,
               format: :m4b,
               narrator: "Scott Brick",
               duration_seconds: 38_000,
               track_number: 1,
               disc_number: 1,
               chapter_count: 42
             })

    reloaded = Repo.get!(BookFile, file.id)

    assert reloaded.narrator == "Scott Brick"
    assert reloaded.duration_seconds == 38_000
    assert reloaded.track_number == 1
    assert reloaded.disc_number == 1
    assert reloaded.chapter_count == 42
  end

  test "an e-book file leaves every new audiobook field nil, unchanged behavior", %{
    ebook_target: target,
    id: id
  } do
    assert {:ok, file} =
             Books.Files.record_import(target, %{
               path: "/tmp/book-#{id}-c.epub",
               size: 4096,
               format: :epub
             })

    assert file.narrator == nil
    assert file.duration_seconds == nil
    assert file.track_number == nil
    assert file.disc_number == nil
    assert file.chapter_count == nil
  end

  defp identifier(id), do: %{provider: "openlibrary", kind: "work", foreign_id: id}
  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
