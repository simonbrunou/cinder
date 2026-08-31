defmodule Cinder.Library.BookNamingTest do
  @moduledoc """
  Destination naming. Pure functions — no filesystem, no Repo — so every case here is about what
  string is produced, not about what lands on disk.

  The security-relevant cases are the ones where a provider title or a release filename tries to
  become a path: `PathPolicy.destination/3` vets the result again before any write, but naming
  must not hand it something to vet in the first place.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.{Author, Credit, Work}
  alias Cinder.Library.BookNaming

  @root "/library/books"

  describe "book_dest/3" do
    test "is root/Author/Title/<preserved filename>" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])

      assert BookNaming.book_dest(work, "/downloads/x/dispossessed.epub", @root) ==
               "/library/books/Ursula K. Le Guin/The Dispossessed/dispossessed.epub"
    end

    test "preserves the release filename verbatim, including scene noise" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      source = "/downloads/Le.Guin.The.Dispossessed.1974.Retail.EPUB-GRP.epub"

      # Automatic renaming is off for migration parity: the filename is evidence of its origin.
      assert BookNaming.book_dest(work, source, @root) ==
               "/library/books/Ursula K. Le Guin/The Dispossessed/" <>
                 "Le.Guin.The.Dispossessed.1974.Retail.EPUB-GRP.epub"
    end

    test "only the first author names the folder" do
      work = work("Good Omens", ["Terry Pratchett", "Neil Gaiman"])

      # A co-authored work lives in one place, not two, and not in a combinatorial folder name.
      assert BookNaming.book_dest(work, "/d/omens.epub", @root) ==
               "/library/books/Terry Pratchett/Good Omens/omens.epub"
    end

    test "credit position decides the folder, not insertion order" do
      work = %Work{
        title: "Good Omens",
        credits: [
          %Credit{role: "author", position: 1, author: %Author{name: "Neil Gaiman"}},
          %Credit{role: "author", position: 0, author: %Author{name: "Terry Pratchett"}}
        ]
      }

      assert BookNaming.book_dest(work, "/d/omens.epub", @root) ==
               "/library/books/Terry Pratchett/Good Omens/omens.epub"
    end

    test "a non-author credit never names the folder" do
      work = %Work{
        title: "Beowulf",
        credits: [
          %Credit{role: "translator", position: 0, author: %Author{name: "Seamus Heaney"}},
          %Credit{role: "author", position: 1, author: %Author{name: "Unknown"}}
        ]
      }

      # A translator's name appears on many unrelated works; only an author credit is identity.
      assert BookNaming.book_dest(work, "/d/beowulf.epub", @root) ==
               "/library/books/Unknown/Beowulf/beowulf.epub"
    end

    test "a work with no author credit lands under Unknown Author" do
      work = %Work{title: "Beowulf", credits: []}

      assert BookNaming.book_dest(work, "/d/beowulf.epub", @root) ==
               "/library/books/Unknown Author/Beowulf/beowulf.epub"
    end

    test "unloaded credits degrade rather than raise" do
      work = %Work{title: "Beowulf", credits: %Ecto.Association.NotLoaded{}}

      assert BookNaming.book_dest(work, "/d/beowulf.epub", @root) ==
               "/library/books/Unknown Author/Beowulf/beowulf.epub"
    end
  end

  describe "path escapes" do
    test "separators in a provider title cannot create directories" do
      work = work("Anna Karenina: Part 1/2", ["Leo Tolstoy"])

      dest = BookNaming.book_dest(work, "/d/anna.epub", @root)

      assert dest == "/library/books/Leo Tolstoy/Anna Karenina Part 12/anna.epub"
      assert Path.dirname(dest) |> Path.split() |> length() == 5
    end

    test "a traversal title cannot climb out of the root" do
      work = work("..", [".."])

      dest = BookNaming.book_dest(work, "/d/book.epub", @root)

      # Dots-only components collapse to the neutral fallbacks rather than becoming `..` segments.
      assert dest == "/library/books/Unknown Author/Untitled/book.epub"
      assert String.starts_with?(dest, @root <> "/")
    end

    test "a traversal filename cannot climb out of the destination folder" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])

      dest = BookNaming.book_dest(work, "/downloads/../../etc/passwd.epub", @root)

      # `Path.basename/1` drops the directory part before it is ever joined.
      assert dest == "/library/books/Ursula K. Le Guin/The Dispossessed/passwd.epub"
    end

    test "a dots-only filename does not become a climbing segment" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])

      dest = BookNaming.book_dest(work, "/downloads/..", @root)

      assert dest == "/library/books/Ursula K. Le Guin/The Dispossessed/book"
      assert String.starts_with?(dest, @root <> "/")
    end

    test "an all-illegal title falls back rather than collapsing the path" do
      work = work("///", ["Ursula K. Le Guin"])

      assert BookNaming.book_dest(work, "/d/book.epub", @root) ==
               "/library/books/Ursula K. Le Guin/Untitled/book.epub"
    end
  end

  defp work(title, author_names) do
    credits =
      author_names
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        %Credit{role: "author", position: index, author: %Author{name: name}}
      end)

    %Work{title: title, credits: credits}
  end
end
