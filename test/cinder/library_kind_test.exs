defmodule Cinder.LibraryKindTest do
  use ExUnit.Case, async: true

  alias Cinder.LibraryKind

  test "lists every library kind and keeps video kinds narrow" do
    assert LibraryKind.all() == [:movies, :tv, :books, :audiobooks]
    assert LibraryKind.video() == [:movies, :tv]
    assert LibraryKind.video?(:movies)
    refute LibraryKind.video?(:books)
  end

  test "the library derives its kinds from the video capability" do
    assert Cinder.Library.kinds() == LibraryKind.video()
  end

  test "book kinds support only standard handling" do
    assert LibraryKind.handlings(:books) == [:standard]
    assert LibraryKind.handlings(:audiobooks) == [:standard]
    refute LibraryKind.handling?(:books, :anime)
  end

  test "labels cover every library kind" do
    assert Enum.map(LibraryKind.all(), &LibraryKind.label/1) ==
             ["Movies", "TV", "Books", "Audiobooks"]
  end
end
