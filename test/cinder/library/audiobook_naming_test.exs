defmodule Cinder.Library.AudiobookNamingTest do
  @moduledoc """
  Destination naming for audiobook tracks. Pure functions — no filesystem, no Repo.

  Unlike `BookNamingTest`, every destination here is derived ONLY from (Author, Title, disc,
  track order) — never from a source filename, which this module deliberately never even takes
  as an argument. See the module's own moduledoc for why: determinism across two different
  uploaders' releases of the same book.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.{Author, Credit, Work}
  alias Cinder.Library.AudiobookNaming

  @root "/library/audiobooks"

  describe "track_dest/4 — single-file set" do
    test "lands at root/Author/Title/Title.ext, unchanged shape from a single-file e-book import" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])

      assert AudiobookNaming.track_dest(work, :m4b, @root, %{index: 1, total: 1}) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/The Dispossessed.m4b"
    end

    test "ignores disc metadata entirely for a single-file set" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])

      meta = %{index: 1, total: 1, disc: 7, multi_disc?: true}

      assert AudiobookNaming.track_dest(work, :m4b, @root, meta) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/The Dispossessed.m4b"
    end
  end

  describe "track_dest/4 — multi-track set" do
    test "numbers tracks NN - Title.ext, zero-padded to 2 digits for <= 99 tracks" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      meta = %{index: 3, total: 12, disc: 1, multi_disc?: false}

      assert AudiobookNaming.track_dest(work, :mp3, @root, meta) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/03 - The Dispossessed.mp3"
    end

    test "widens the zero-pad for a set past 99 tracks" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      meta = %{index: 7, total: 120, disc: 1, multi_disc?: false}

      assert AudiobookNaming.track_dest(work, :mp3, @root, meta) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/007 - The Dispossessed.mp3"
    end

    test "no Disc segment for a single-disc multi-track set" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      meta = %{index: 1, total: 2, disc: 1, multi_disc?: false}

      assert AudiobookNaming.track_dest(work, :mp3, @root, meta) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/01 - The Dispossessed.mp3"
    end

    test "a Disc M/ segment only when the resolved set spans more than one disc" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      meta = %{index: 7, total: 20, disc: 2, multi_disc?: true}

      assert AudiobookNaming.track_dest(work, :mp3, @root, meta) ==
               "/library/audiobooks/Ursula K. Le Guin/The Dispossessed/Disc 2/" <>
                 "07 - The Dispossessed.mp3"
    end

    # The determinism property this module's whole moduledoc is about: two releases with
    # different filenames but the SAME track/disc shape compute the IDENTICAL destination.
    test "is independent of any source filename — never taken as an argument" do
      work = work("The Dispossessed", ["Ursula K. Le Guin"])
      meta = %{index: 1, total: 2, disc: 1, multi_disc?: false}

      assert AudiobookNaming.track_dest(work, :mp3, @root, meta) ==
               AudiobookNaming.track_dest(work, :mp3, @root, meta)
    end
  end

  describe "path escapes" do
    test "an all-illegal title falls back rather than collapsing the path" do
      work = work("////", ["Ursula K. Le Guin"])

      assert AudiobookNaming.track_dest(work, :m4b, @root, %{index: 1, total: 1}) ==
               "/library/audiobooks/Ursula K. Le Guin/Untitled/Untitled.m4b"
    end

    test "a title that sanitizes to a leading dot does not become a hidden folder or file" do
      work = work(".hackLegend of the Twilight", ["Author"])

      assert AudiobookNaming.track_dest(work, :m4b, @root, %{index: 1, total: 1}) ==
               "/library/audiobooks/Author/_.hackLegend of the Twilight/" <>
                 "_.hackLegend of the Twilight.m4b"
    end

    test "a dots-only traversal title collapses to Untitled rather than a climbing segment" do
      work = work("..", [".."])

      dest = AudiobookNaming.track_dest(work, :m4b, @root, %{index: 1, total: 1})

      assert dest == "/library/audiobooks/Unknown Author/Untitled/Untitled.m4b"
      assert String.starts_with?(dest, @root <> "/")
    end

    test "a work with no author credit lands under Unknown Author" do
      work = %Work{title: "Orphaned Work", credits: []}

      assert AudiobookNaming.track_dest(work, :m4b, @root, %{index: 1, total: 1}) ==
               "/library/audiobooks/Unknown Author/Orphaned Work/Orphaned Work.m4b"
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
