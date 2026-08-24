defmodule Cinder.LibraryKindTest do
  use Cinder.DataCase, async: false

  alias Cinder.{Catalog, LibraryKind, Repo, Settings}
  alias Ecto.Adapters.SQL

  test "lists every media kind and keeps video kinds narrow" do
    assert LibraryKind.all() == [:movies, :tv, :ebook, :audiobook]
    assert LibraryKind.video() == [:movies, :tv]
    assert LibraryKind.video?(:movies)
    refute LibraryKind.video?(:ebook)
  end

  test "the library derives its kinds from the video capability" do
    assert Cinder.Library.kinds() == LibraryKind.video()
  end

  test "book media kinds support only standard handling" do
    assert LibraryKind.handlings(:ebook) == [:standard]
    assert LibraryKind.handlings(:audiobook) == [:standard]
    refute LibraryKind.handling?(:ebook, :anime)
  end

  test "labels cover every media kind" do
    assert Enum.map(LibraryKind.all(), &LibraryKind.label/1) ==
             ["Movies", "TV", "Ebooks", "Audiobooks"]
  end

  test "filesystem root roles stay separate from media kinds" do
    assert LibraryKind.root_role(:ebook) == :books
    assert LibraryKind.root_role(:audiobook) == :audiobooks

    for kind <- LibraryKind.video() do
      assert LibraryKind.root_role(kind) == kind
    end

    assert Settings.library_path_key(:ebook) == "books_library_path"
    assert Settings.library_path_key(:movies) == "movies_library_path"
    refute :books in LibraryKind.all()
    refute :ebook in Enum.map(LibraryKind.all(), &LibraryKind.root_role/1)
  end

  test "profile persistence uses the media-kind axis" do
    assert {:error, invalid} =
             Catalog.create_profile(%{name: "Wrong axis", kind: :books, handling: :standard})

    assert errors_on(invalid).kind != []

    assert {:ok, profile} =
             Catalog.create_profile(%{name: "Ereader", kind: :ebook, handling: :standard})

    assert SQL.query!(Repo, "SELECT kind FROM media_profiles WHERE id = ?", [profile.id]).rows ==
             [
               ["ebook"]
             ]
  end
end
