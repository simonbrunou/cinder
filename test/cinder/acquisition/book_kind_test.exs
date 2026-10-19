defmodule Cinder.Acquisition.BookKindTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.BookKind
  alias Cinder.LibraryKind

  describe "every book kind" do
    test "has rules, so a kind added to LibraryKind cannot reach the judge without them" do
      assert Enum.sort(BookKind.all()) == Enum.sort(LibraryKind.books())

      for kind <- LibraryKind.books() do
        assert %BookKind{media_kind: ^kind} = BookKind.fetch!(kind)
      end
    end

    test "accepts only formats its parser recognizes" do
      for kind <- LibraryKind.books() do
        rules = BookKind.fetch!(kind)
        assert rules.accepted_formats -- rules.known_formats == [], "#{kind}"
      end
    end

    test "lists each recognized format once" do
      for kind <- LibraryKind.books() do
        formats = BookKind.fetch!(kind).known_formats
        assert formats == Enum.uniq(formats), "#{kind}"
      end
    end

    test "has a size band whose floor is below its ceiling" do
      for kind <- LibraryKind.books() do
        {min, max} = BookKind.size_band(kind)
        assert 0 < min and min < max, "#{kind}"
      end
    end
  end

  test "a video kind has no book rules" do
    assert_raise ArgumentError, fn -> BookKind.fetch!(:movies) end
  end

  test "the e-book kind takes the parity contract's formats: EPUB, AZW3, MOBI, EPUB first" do
    assert BookKind.accepted_formats(:ebook) == [:epub, :azw3, :mobi]
    assert BookKind.size_band(:ebook) == {64 * 1024, 200 * 1024 * 1024}
    refute BookKind.fetch!(:ebook).narrated?
  end

  test "the audiobook kind is B7a's own judgment: M4B and MP3, M4B first, 5 MB - 8 GB" do
    assert BookKind.accepted_formats(:audiobook) == [:m4b, :mp3]
    assert BookKind.size_band(:audiobook) == {5 * 1024 * 1024, 8 * 1024 * 1024 * 1024}
    assert BookKind.fetch!(:audiobook).narrated?
  end

  test "each kind recognizes the containers it must refuse by name" do
    assert :pdf in BookKind.fetch!(:ebook).known_formats

    assert Enum.sort(BookKind.fetch!(:audiobook).known_formats) ==
             Enum.sort([:m4b, :mp3, :m4a, :aac, :flac, :ogg, :wma, :epub, :azw3, :mobi])

    refute :epub in BookKind.accepted_formats(:audiobook)
  end
end
