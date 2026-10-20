defmodule Cinder.Acquisition.BookScorerKindTest do
  # What only one book kind does. The judge's shared behaviour runs for both kinds in
  # `book_scorer_test.exs`.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{AudiobookRelease, BookScorer, EbookRelease}

  @beloved %{title: "Beloved", authors: ["Toni Morrison"]}
  @dune %{title: "Dune", authors: ["Frank Herbert"]}
  @hail_mary %{title: "Project Hail Mary", authors: ["Andy Weir"]}

  defp ebook(title),
    do: EbookRelease.new(%{title: title, size: 2_000_000, download_url: "u", protocol: :torrent})

  defp audiobook(title),
    do:
      AudiobookRelease.new(%{
        title: title,
        size: 100_000_000,
        download_url: "u",
        protocol: :torrent
      })

  test "reasons/0 has no duplicates" do
    reasons = BookScorer.reasons()
    assert Enum.uniq(reasons) == reasons
  end

  describe "e-book" do
    test "accepts AZW3 and MOBI, the other two accepted formats" do
      assert {:accept, %{format: :azw3}} =
               BookScorer.evaluate(ebook("Toni Morrison - Beloved (azw3)"), @beloved)

      assert {:accept, %{format: :mobi}} =
               BookScorer.evaluate(ebook("Toni Morrison - Beloved (mobi)"), @beloved)
    end

    test "refuses a scan format by name" do
      assert {:reject, :format_rejected} =
               BookScorer.evaluate(ebook("Toni Morrison - Beloved (djvu)"), @beloved)
    end

    test "accept evidence carries no narrator" do
      assert {:accept, evidence} =
               BookScorer.evaluate(ebook("Toni Morrison - Beloved (epub)"), @beloved)

      refute Map.has_key?(evidence, :narrator)
    end

    test "a narrator-credit group is not release metadata" do
      # The narrator rule belongs to the audiobook kind: in an e-book release name the group's
      # words are unexplained title evidence like any other unknown bracket.
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 ebook("Andy Weir - Project Hail Mary (Narrated by Ray Porter) (epub)"),
                 @hail_mary
               )
    end
  end

  describe "audiobook" do
    test "accepts MP3, the other accepted format" do
      assert {:accept, %{format: :mp3}} =
               BookScorer.evaluate(audiobook("Toni Morrison - Beloved (MP3)"), @beloved)
    end

    test "an e-book format is a recognized-but-wrong-family rejection, not unknown" do
      assert {:reject, :format_rejected} =
               BookScorer.evaluate(audiobook("Toni Morrison - Beloved (epub)"), @beloved)
    end

    test "an unsupported audio container is rejected with its own reason" do
      assert {:reject, :format_rejected} =
               BookScorer.evaluate(audiobook("Toni Morrison - Beloved (M4A)"), @beloved)

      assert {:reject, :format_rejected} =
               BookScorer.evaluate(audiobook("Toni Morrison - Beloved (FLAC)"), @beloved)
    end
  end

  describe "each kind's own release vocabulary" do
    # "rip" is audiobook metadata; in an e-book release name it is an unexplained title word.
    test "a rip marker is metadata for an audiobook and title evidence for an e-book" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(audiobook("Toni Morrison - Beloved Rip (M4B)"), @beloved)

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(ebook("Toni Morrison - Beloved Rip (epub)"), @beloved)
    end
  end

  describe "audiobook narrator credit never gates acceptance" do
    test "a release with a narrator credit is accepted, and the credit rides in evidence" do
      assert {:accept, %{narrator: "Ray Porter"}} =
               BookScorer.evaluate(
                 audiobook("Andy Weir - Project Hail Mary (Narrated by Ray Porter) (M4B)"),
                 @hail_mary
               )
    end

    test "the same release is accepted whether or not it carries a narrator" do
      assert {:accept, %{narrator: nil}} =
               BookScorer.evaluate(audiobook("Andy Weir - Project Hail Mary (M4B)"), @hail_mary)
    end

    test "an unrecognized narrator NAME does not produce a title mismatch" do
      # Without narrator-group stripping, "Some Unknown Reader"'s tokens would leak into the
      # title remainder and this would wrongly reject with :title_mismatch.
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 audiobook("Frank Herbert - Dune (Read by Some Unknown Reader) (M4B)"),
                 @dune
               )
    end
  end
end
