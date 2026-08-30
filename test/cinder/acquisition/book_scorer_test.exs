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

  describe "bracket and colon bypasses" do
    # Each of these erased a sequel name and accepted a different book. They are grouped because
    # they are one mistake in two places: treating unknown text as noise because of where it sits.
    test "a one-word sequel in a trailing bracket is not a tracker tag" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune (epub) (Messiah)"), @dune)

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune (epub) [Messiah]"), @dune)
    end

    test "a real tracker handle after the format is still dropped" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Frank Herbert - Dune (epub) [MyAnonaMouse]"), @dune)
    end

    test "a subtitle that restates the requested title is a sequel, not a subtitle" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release("Frank Herbert - Dune: Children of Dune (epub)"),
                 @dune
               )
    end

    test "a genuine descriptive subtitle is still forgiven" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Frank Herbert - Dune: The Story of Paul (epub)"),
                 @dune
               )
    end
  end

  describe "works whose titles are collection words" do
    test "a 'Complete Works' request accepts its own release" do
      work = %{title: "Complete Works", authors: ["William Shakespeare"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("William Shakespeare - Complete Works (epub)"),
                 work
               )
    end
  end

  describe "contradictory formats" do
    # The contract fails closed on "unknown OR CONTRADICTORY formats". An accepted format beside a
    # rejected one may be a bundle or a mis-tagged scan, and nothing in the name says which.
    test "an accepted format advertised beside a rejected one is refused" do
      assert {:reject, :format_contradictory} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub) (pdf)"), @beloved)

      assert {:reject, :format_contradictory} =
               BookScorer.evaluate(release("Toni Morrison - Beloved [EPUB/PDF]"), @beloved)
    end

    test "two ACCEPTED formats are a bundle, not a contradiction" do
      assert {:accept, %{format: :epub}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub, azw3)"), @beloved)

      assert {:accept, %{format: :epub}} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub) (mobi)"), @beloved)
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
      # The series must be LOADED for its name to be discountable — an unrecognized bracket group
      # is title evidence, not noise. `Books.normalize/1` supplies this from series_memberships.
      work = Map.put(@dispossessed, :series, ["Hainish Cycle"])

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Ursula K. Le Guin - The Dispossessed (Hainish Cycle) (1974) (epub)"),
                 work
               )
    end

    test "an unknown bracketed group is title evidence, not noise" do
      # Dropping every bracketed group unconditionally made brackets a bypass: "Dune (Messiah)"
      # erased to "Dune" and was accepted for a request for Dune.
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune (Messiah) (epub)"), @dune)

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune [Messiah] (epub)"), @dune)
    end

    test "a trailing tracker tag after the format is still dropped" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release("Toni Morrison - Beloved (epub) [MyAnonaMouse]"),
                 @beloved
               )
    end

    test "a colon does not license a sequel name as a subtitle" do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release("Frank Herbert - Dune: Messiah (epub)"), @dune)
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

    test "an untagged release satisfies an ENGLISH request only" do
      # Untagged means English by scene convention, so it satisfies English and nothing else.
      # Passing every request handed a household asking for French an almost-certainly-English
      # file — the same fail-open `Cinder.Acquisition.Language` closed for video.
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved,
                 language: "en"
               )

      assert {:reject, :language_mismatch} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved,
                 language: "fr"
               )
    end

    test "a three-letter ISO 639-2 code matches the parser's tag" do
      # Open Library publishes `/languages/eng`, so a caller passing `edition.language` straight
      # through supplies "eng" — which upcased to "ENG" and matched no tag the parser emits,
      # rejecting a correctly-tagged English release as the wrong language.
      for code <- ["eng", "en"] do
        assert {:accept, %{language: "ENGLISH"}} =
                 BookScorer.evaluate(
                   release("Toni Morrison - Beloved [ENGLISH] (epub)"),
                   @beloved,
                   language: code
                 ),
               "#{code} did not match ENGLISH"
      end

      for code <- ["fre", "fra", "fr"] do
        assert {:accept, %{language: "FRENCH"}} =
                 BookScorer.evaluate(
                   release("Toni Morrison - Beloved [FRENCH] (epub)"),
                   @beloved,
                   language: code
                 ),
               "#{code} did not match FRENCH"
      end
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

  describe "abridgement" do
    # An abridged text is a DIFFERENT text. The contract groups abridged/unabridged ambiguity with
    # omnibus and anthology and requires an explained rejection.
    test "an abridged release is refused with its own reason" do
      assert {:reject, :abridged_edition} =
               BookScorer.evaluate(release("Toni Morrison - Beloved Abridged (epub)"), @beloved)

      assert {:reject, :abridged_edition} =
               BookScorer.evaluate(release("Toni Morrison - Beloved (Abridged) (epub)"), @beloved)
    end

    test "'unabridged' is not read as 'abridged'" do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved Unabridged (epub)"), @beloved)
    end

    test "a request that explicitly wants the abridged edition accepts one" do
      work = Map.put(@beloved, :abridged, true)

      assert {:accept, _evidence} =
               BookScorer.evaluate(release("Toni Morrison - Beloved Abridged (epub)"), work)
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
      # Distinguished by tracker tag, not by a bare letter: a one-letter bracket group is not a
      # recognizable tracker handle, and unknown bracket content is title evidence now.
      releases = [
        release("Toni Morrison - Beloved (epub) [Tracker1]", size: 40_000_000),
        release("Toni Morrison - Beloved (epub) [Tracker2]", size: 3_000_000)
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

    test "a non-English request drops the untagged release rather than ranking it" do
      # An untagged release is English by convention, so it satisfies an English request and
      # nothing else — it is rejected here, not merely out-ranked.
      releases = [
        release("Toni Morrison - Beloved (epub)"),
        release("Toni Morrison - Beloved [FRENCH] (epub)")
      ]

      %{accepted: accepted, rejected: rejected} =
        BookScorer.evaluate_all(releases, @beloved, language: "fr")

      assert ["Toni Morrison - Beloved [FRENCH] (epub)"] =
               Enum.map(accepted, fn {release, _evidence} -> release.title end)

      assert [{_release, :language_mismatch}] = rejected
    end

    test "returns empty lists for no input" do
      assert %{accepted: [], rejected: []} = BookScorer.evaluate_all([], @beloved)
    end
  end

  test "accepted_formats/0 is the parity contract's e-book profile, EPUB first" do
    assert BookScorer.accepted_formats() == [:epub, :azw3, :mobi]
  end
end
