defmodule Cinder.Acquisition.BookScorerTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{BookRelease, BookScorer}

  # Works drawn from the B0 frozen corpus so the scorer and the identity resolver are exercised on
  # one vocabulary (see test/support/fixtures/books/corpus-v1.json).
  @beloved %{title: "Beloved", authors: ["Toni Morrison"]}
  @dispossessed %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @dune %{title: "Dune", authors: ["Frank Herbert"]}

  defp release(title, attrs \\ []) do
    BookRelease.new(
      Enum.into(attrs, %{
        title: title,
        size: 2_000_000,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent
      })
    )
  end

  describe "format is fail-closed" do
    test "accepts an EPUB" do
      assert {:accept, %{format: :epub}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved)
    end

    test "accepts AZW3 and MOBI, the other two profile formats" do
      assert {:accept, %{format: :azw3}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (azw3)"), @beloved)

      assert {:accept, %{format: :mobi}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (mobi)"), @beloved)
    end

    test "an unstated format is rejected rather than assumed" do
      assert {:reject, :format_unknown} =
               BookScorer.evaluate(release("Toni Morrison - Beloved"), @beloved)
    end

    test "a recognized format outside the profile is rejected with its own reason" do
      assert {:reject, :format_rejected} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (pdf)"), @beloved)

      assert {:reject, :format_rejected} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (djvu)"), @beloved)
    end

    test "a multi-format release is accepted at its best profile format" do
      assert {:accept, %{format: :epub, formats: formats}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (MOBI, EPUB)"), @beloved)

      assert Enum.sort(formats) == [:epub, :mobi]
    end
  end

  describe "author evidence" do
    test "requires the author's tokens to be present" do
      assert {:reject, :author_mismatch} =
               BookScorer.evaluate(release("Someone Else - Beloved (epub)"), @beloved)
    end

    test "matches regardless of name order" do
      work = %{title: "The Three-Body Problem", authors: ["Cixin Liu"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Liu Cixin - The Three-Body Problem (epub)"), work)
    end

    test "matches across diacritics and punctuation" do
      work = %{title: "Les Miserables", authors: ["Victor Hugo"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Victor Hugo - Les Misérables (epub)"), work)
    end

    test "a work with no known author cannot be matched" do
      assert {:reject, :author_mismatch} =
               BookScorer.evaluate(release("Anon - Beloved (epub)"), %{
                 title: "Beloved",
                 authors: []
               })
    end
  end

  describe "title evidence" do
    test "rejects a different work by the same author" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Toni Morrison - Song of Solomon (epub)"), @beloved)
    end

    test "tolerates series, year, and group noise around the title" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Ursula K. Le Guin - The Dispossessed (Hainish Cycle) (1974) (epub)"),
                 @dispossessed
               )
    end

    test "tolerates a missing leading article" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Ursula K. Le Guin - Dispossessed (epub)"),
                 @dispossessed
               )
    end

    # The wrong-work family that plain title CONTAINMENT accepts. Each of these carries every token
    # of the requested title and is a different book, so they are the reason `check_title/2` bounds
    # the remainder instead of only testing containment. Found by probing the first implementation,
    # which accepted all four.
    test "rejects a sequel whose name contains the requested title" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune Messiah (epub)"), @dune)
    end

    test "rejects a companion work whose name contains the requested title" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - The Dune Encyclopedia (epub)"), @dune)
    end

    test "rejects a superset title that only appends one word" do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release("Brandon Sanderson - The Way of Kings Prime (epub)"),
                 work
               )
    end

    test "rejects a different work whose name embeds a short requested title" do
      work = %{title: "It", authors: ["Stephen King"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release("Stephen King - It Chapter Two Companion (epub)"),
                 work
               )
    end

    # The other half of the trade: the remainder bound must not reject the shapes real indexers
    # actually publish. Each of these was rejected by the first bounded implementation.
    test "accepts a dot-separated scene name with a year and a group tag" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Frank.Herbert-Dune.2019.Retail.EPUB.eBook-BitBook"),
                 @dune
               )
    end

    test "accepts a release naming the work's subtitle when the request did not" do
      work = %{title: "Sapiens", authors: ["Yuval Noah Harari"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Yuval Noah Harari - Sapiens: A Brief History of Humankind (epub)"),
                 work
               )
    end

    test "accepts a series-numbered release when the work carries that series" do
      work = %{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        series: ["The Stormlight Archive"]
      }

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(
                   "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings (epub)"
                 ),
                 work
               )
    end

    test "a loaded series does not admit a different book in the same series" do
      work = %{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        series: ["The Stormlight Archive"]
      }

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(
                   "Brandon Sanderson - The Stormlight Archive 02 - Words of Radiance (epub)"
                 ),
                 work
               )
    end
  end

  describe "protocol" do
    test "rejects a release whose protocol has no configured client" do
      release = release("Toni Morrison - Beloved (epub)", protocol: :usenet)

      assert {:reject, :wrong_protocol} =
               BookScorer.evaluate(release, @beloved, protocols: [:torrent])
    end

    test "accepts the same release when its protocol is configured" do
      release = release("Toni Morrison - Beloved (epub)", protocol: :usenet)
      assert {:accept, _evidence} = BookScorer.evaluate(release, @beloved, protocols: [:usenet])
    end

    test "no protocols option means no gate" do
      release = release("Toni Morrison - Beloved (epub)", protocol: :usenet)
      assert {:accept, _evidence} = BookScorer.evaluate(release, @beloved)
    end
  end

  describe "unfoldable titles" do
    # Folding to ASCII DISCARDS non-Latin script, so two different works can share their Latin
    # residue. `Cinder.Books.Identity` refuses these for the same reason; the scorer must not be
    # the weaker gate.
    test "a non-Latin title is refused rather than compared on its Latin residue" do
      work = %{title: "ノルウェイの森 1", authors: ["Haruki Murakami"]}

      assert {:reject, :title_unfoldable} =
               BookScorer.evaluate(release("Haruki Murakami - 海辺のカフカ 1 (epub)"), work)
    end

    test "a non-Latin release name cannot satisfy a Latin-titled work" do
      work = %{title: "Norwegian Wood", authors: ["Haruki Murakami"]}

      assert {:reject, :title_unfoldable} =
               BookScorer.evaluate(release("Haruki Murakami - 海辺のカフカ (epub)"), work)
    end

    test "diacritics are not lossy — accented Latin still compares" do
      work = %{title: "Les Misérables", authors: ["Victor Hugo"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Victor Hugo - Les Miserables (epub)"), work)
    end
  end

  describe "collection ambiguity" do
    test "an omnibus containing the requested title is refused with its own reason" do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(
                   "Brandon Sanderson - Stormlight Archive Books 1-3 (The Way of Kings, Words of Radiance, Oathbringer) (epub)"
                 ),
                 work
               )
    end

    test "the single volume of the same series is accepted" do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Brandon Sanderson - The Way of Kings (epub)"),
                 work
               )
    end

    # A work whose OWN title carries a collection word is an ordinary request, not an ambiguity.
    # An unconditional reject made every one of these permanently unrequestable, with a reason that
    # blamed the release for saying what the work is called.
    test "a work whose own title is an anthology can still be requested" do
      work = %{title: "The Norton Anthology of Poetry", authors: ["Margaret Ferguson"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Margaret Ferguson - The Norton Anthology of Poetry (epub)"),
                 work
               )
    end

    test "a work whose own title contains 'Collection' can still be requested" do
      work = %{title: "Collection Agency", authors: ["Some Author"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Some Author - Collection Agency (epub)"), work)
    end

    test "a pack still refuses when the request never mentioned a collection" do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release("Brandon Sanderson - The Way of Kings (Stormlight Omnibus) (epub)"),
                 work
               )
    end
  end

  describe "language" do
    test "no requested language means no gate" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved [FRENCH] (epub)"), @beloved)
    end

    test "an untagged release satisfies a requested language" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved,
                 language: "en"
               )
    end

    test "a contradicting language is rejected" do
      assert {:reject, :language_mismatch} =
               BookScorer.evaluate(release("Toni Morrison - Beloved [FRENCH] (epub)"), @beloved,
                 language: "en"
               )
    end

    test "a matching language is accepted by ISO code" do
      assert {:accept, %{language: "FRENCH"}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved [FRENCH] (epub)"), @beloved,
                 language: "fr"
               )
    end

    test "MULTI satisfies any requested language" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub) [MULTI]"), @beloved,
                 language: "fr"
               )
    end
  end

  describe "size band" do
    test "rejects a stub below the floor" do
      assert {:reject, :size_out_of_band} =
               BookScorer.evaluate(
                 release("Toni Morrison - Beloved (epub)", size: 1_000),
                 @beloved
               )
    end

    test "rejects a multi-gigabyte pack above the ceiling" do
      assert {:reject, :size_out_of_band} =
               BookScorer.evaluate(
                 release("Toni Morrison - Beloved (epub)", size: 4_000_000_000),
                 @beloved
               )
    end

    test "an unreported size passes rather than filtering out the whole indexer" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)", size: nil), @beloved)
    end
  end

  describe "blocked terms" do
    test "a blocked substring rejects the release" do
      assert {:reject, :blocked_term} =
               BookScorer.evaluate(
                 release("Toni Morrison - Beloved (epub) [SAMPLE]"),
                 @beloved,
                 blocked_terms: ["sample"]
               )
    end

    test "a blank blocked term matches nothing" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved,
                 blocked_terms: ["", "   "]
               )
    end
  end

  describe "evaluate_all/3" do
    test "ranks accepted releases and explains every rejection" do
      releases = [
        release("Toni Morrison - Beloved (mobi)", size: 2_000_000),
        release("Toni Morrison - Beloved (pdf)", size: 2_000_000),
        release("Toni Morrison - Beloved (epub)", size: 5_000_000),
        release("Toni Morrison - Beloved (epub) [retail]", size: 6_000_000),
        release("Someone Else - Beloved (epub)", size: 2_000_000)
      ]

      %{accepted: accepted, rejected: rejected} = BookScorer.evaluate_all(releases, @beloved)

      assert [first, second, third] = Enum.map(accepted, fn {release, _e} -> release.title end)
      # EPUB outranks MOBI; retail outranks non-retail within the same format.
      assert first == "Toni Morrison - Beloved (epub) [retail]"
      assert second == "Toni Morrison - Beloved (epub)"
      assert third == "Toni Morrison - Beloved (mobi)"

      assert Enum.sort(Enum.map(rejected, fn {_release, reason} -> reason end)) ==
               [:author_mismatch, :format_rejected]
    end

    test "prefers the smaller file among otherwise equal candidates" do
      releases = [
        release("Toni Morrison - Beloved (epub) [a]", size: 40_000_000),
        release("Toni Morrison - Beloved (epub) [b]", size: 3_000_000)
      ]

      %{accepted: [{best, _evidence} | _rest]} = BookScorer.evaluate_all(releases, @beloved)

      assert best.size == 3_000_000
    end

    test "an untagged release outranks a foreign-tagged one when no language is asked for" do
      # Being tagged at all must not be a promotion: an untagged book release is overwhelmingly
      # English, so a [FRENCH] copy sorting first handed the household the wrong language.
      releases = [
        release("Toni Morrison - Beloved [FRENCH] (epub)"),
        release("Toni Morrison - Beloved (epub)")
      ]

      %{accepted: accepted} = BookScorer.evaluate_all(releases, @beloved)

      assert ["Toni Morrison - Beloved (epub)", "Toni Morrison - Beloved [FRENCH] (epub)"] =
               Enum.map(accepted, fn {release, _evidence} -> release.title end)
    end

    test "the requested language outranks an untagged release when one IS asked for" do
      releases = [
        release("Toni Morrison - Beloved (epub)"),
        release("Toni Morrison - Beloved [FRENCH] (epub)")
      ]

      %{accepted: accepted} = BookScorer.evaluate_all(releases, @beloved, language: "fr")

      assert ["Toni Morrison - Beloved [FRENCH] (epub)", "Toni Morrison - Beloved (epub)"] =
               Enum.map(accepted, fn {release, _evidence} -> release.title end)
    end

    test "returns empty lists for no input" do
      assert %{accepted: [], rejected: []} = BookScorer.evaluate_all([], @beloved)
    end
  end

  test "accepted_formats/0 is the parity contract's e-book profile, EPUB first" do
    assert BookScorer.accepted_formats() == [:epub, :azw3, :mobi]
  end
end
