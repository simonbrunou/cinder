defmodule Cinder.MediaKindTest do
  use ExUnit.Case, async: true

  alias Cinder.MediaKind

  test "lists every media kind and keeps video kinds narrow" do
    assert MediaKind.all() == [:movies, :tv, :ebooks, :audiobooks]
    assert MediaKind.video() == [:movies, :tv]
    assert MediaKind.video?(:movies)
    refute MediaKind.video?(:ebooks)
  end

  test "the library derives its kinds from the video capability" do
    assert Cinder.Library.kinds() == MediaKind.video()
  end

  test "book kinds support only standard handling" do
    assert MediaKind.handlings(:ebooks) == [:standard]
    assert MediaKind.handlings(:audiobooks) == [:standard]
    refute MediaKind.handling?(:ebooks, :anime)
  end

  test "labels cover every media kind" do
    assert Enum.map(MediaKind.all(), &MediaKind.label/1) ==
             ["Movies", "TV", "Ebooks", "Audiobooks"]
  end
end
