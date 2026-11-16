defmodule Cinder.Library.BookFoldersTest do
  @moduledoc """
  The `Author/Title` folder names both book kinds share. Pure functions — no filesystem, no Repo.

  `EbookNamingTest` and `AudiobookNamingTest` check the same rules through each kind's whole
  destination path; these cases check the folder strings themselves, one rule each.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.{Author, Credit, Work}
  alias Cinder.Library.BookFolders

  describe "author_folder/1" do
    test "is the author's name" do
      assert BookFolders.author_folder(work("Beowulf", ["Ursula K. Le Guin"])) ==
               "Ursula K. Le Guin"
    end

    test "only the lowest-positioned author credit names the folder" do
      work = %Work{
        title: "Good Omens",
        credits: [
          %Credit{role: "author", position: 1, author: %Author{id: 1, name: "Neil Gaiman"}},
          %Credit{role: "author", position: 0, author: %Author{id: 2, name: "Terry Pratchett"}}
        ]
      }

      assert BookFolders.author_folder(work) == "Terry Pratchett"
    end

    test "a position tie breaks on the author's id, not on the credit order" do
      work = %Work{
        title: "Good Omens",
        credits: [
          %Credit{role: "author", position: 0, author: %Author{id: 9, name: "Neil Gaiman"}},
          %Credit{role: "author", position: 0, author: %Author{id: 3, name: "Terry Pratchett"}}
        ]
      }

      assert BookFolders.author_folder(work) == "Terry Pratchett"
    end

    test "a credit with no position counts as position 0" do
      work = %Work{
        title: "Good Omens",
        credits: [
          %Credit{role: "author", position: 1, author: %Author{id: 1, name: "Terry Pratchett"}},
          %Credit{role: "author", position: nil, author: %Author{id: 2, name: "Neil Gaiman"}}
        ]
      }

      assert BookFolders.author_folder(work) == "Neil Gaiman"
    end

    test "a non-author credit, or an author with no name, never names the folder" do
      work = %Work{
        title: "Beowulf",
        credits: [
          %Credit{role: "translator", position: 0, author: %Author{name: "Seamus Heaney"}},
          %Credit{role: "author", position: 0, author: %Author{name: nil}},
          %Credit{role: "author", position: 1, author: %Author{name: "Unknown"}}
        ]
      }

      assert BookFolders.author_folder(work) == "Unknown"
    end

    test "no author credit, or unloaded credits, is Unknown Author" do
      assert BookFolders.author_folder(%Work{title: "Beowulf", credits: []}) == "Unknown Author"

      assert BookFolders.author_folder(%Work{
               title: "Beowulf",
               credits: %Ecto.Association.NotLoaded{}
             }) == "Unknown Author"
    end

    test "an author that sanitizes to nothing, or to dots only, is Unknown Author" do
      assert BookFolders.author_folder(work("Beowulf", ["///"])) == "Unknown Author"
      assert BookFolders.author_folder(work("Beowulf", [" .. "])) == "Unknown Author"
    end

    test "strips illegal characters and surrounding whitespace" do
      assert BookFolders.author_folder(work("Beowulf", ["  Le Guin: <U.K.>  "])) == "Le Guin U.K."
    end

    test "an author that sanitizes to a leading dot is prefixed, not hidden" do
      assert BookFolders.author_folder(work("Beowulf", [".hack Collective"])) ==
               "_.hack Collective"
    end
  end

  describe "title_folder/1" do
    test "is the work's title" do
      assert BookFolders.title_folder(work("The Dispossessed", [])) == "The Dispossessed"
    end

    test "takes any map with a title" do
      assert BookFolders.title_folder(%{title: "The Dispossessed"}) == "The Dispossessed"
    end

    test "separators in a title cannot create directories" do
      assert BookFolders.title_folder(%{title: "Anna Karenina: Part 1/2"}) ==
               "Anna Karenina Part 12"
    end

    test "a title that sanitizes to nothing, to dots only, or is not a string is Untitled" do
      for title <- ["///", "..", " . ", "", nil] do
        assert BookFolders.title_folder(%{title: title}) == "Untitled", inspect(title)
      end
    end

    test "a title that sanitizes to a leading dot is prefixed, not hidden" do
      assert BookFolders.title_folder(%{title: ".hack//Legend of the Twilight"}) ==
               "_.hackLegend of the Twilight"
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
