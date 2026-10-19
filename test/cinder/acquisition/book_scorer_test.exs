defmodule Cinder.Acquisition.BookScorerTest do
  # The judge's shared behaviour, run once per book kind: everything here must hold for an e-book
  # and an audiobook release alike. What only one kind does (its format set, the narrator credit,
  # its own release vocabulary) lives in `book_scorer_kind_test.exs`.
  use ExUnit.Case,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  alias Cinder.Acquisition.{AudiobookRelease, BookKind, BookRelease, BookScorer}

  # Works drawn from the B0 frozen corpus so the scorer and the identity resolver are exercised on
  # one vocabulary (see test/support/fixtures/books/corpus-v1.json).
  @beloved %{title: "Beloved", authors: ["Toni Morrison"]}
  @dispossessed %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @dune %{title: "Dune", authors: ["Frank Herbert"]}

  # Per kind: the release struct, the preferred and the second accepted format, a format the kind
  # recognizes but refuses, the kind's own word for itself in a release name, and a default size
  # comfortably inside its band.
  @kinds %{
    ebook: %{
      struct: BookRelease,
      fmt: "epub",
      alt: "mobi",
      refused: "pdf",
      word: "eBook",
      size: 2_000_000
    },
    audiobook: %{
      struct: AudiobookRelease,
      fmt: "m4b",
      alt: "mp3",
      refused: "m4a",
      word: "Audiobook",
      size: 100_000_000
    }
  }

  # A release name with `{fmt}`, `{alt}`, `{refused}` and `{word}` replaced by the kind's own
  # tokens, so one name describes the same release shape for either kind.
  defp name(%{kind: kind}, title) do
    Enum.reduce([:fmt, :alt, :refused, :word], title, fn key, acc ->
      String.replace(acc, "{#{key}}", @kinds[kind][key])
    end)
  end

  defp release(%{kind: kind} = ctx, title, attrs \\ []) do
    title = name(ctx, title)

    @kinds[kind].struct.new(
      Enum.into(attrs, %{
        title: title,
        size: @kinds[kind].size,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent
      })
    )
  end

  defp format(%{kind: kind}, key), do: String.to_existing_atom(@kinds[kind][key])

  # A size `factor` times the kind's default, so relative sizes keep their meaning in either band.
  defp size(%{kind: kind}, factor), do: round(@kinds[kind].size * factor)

  describe "format is fail-closed" do
    test "accepts the kind's preferred format", ctx do
      preferred = format(ctx, :fmt)

      assert {:accept, %{format: ^preferred}} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved)
    end

    test "an unstated format is rejected rather than assumed", ctx do
      assert {:reject, :format_unknown} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved"), @beloved)
    end

    test "a recognized format outside the kind is rejected with its own reason", ctx do
      assert {:reject, :format_rejected} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({refused})"), @beloved)
    end

    test "a multi-format release is accepted at its best accepted format", ctx do
      preferred = format(ctx, :fmt)

      assert {:accept, %{format: ^preferred, formats: formats}} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({alt}, {fmt})"),
                 @beloved
               )

      assert Enum.sort(formats) == Enum.sort([preferred, format(ctx, :alt)])
    end
  end

  describe "bracket and colon bypasses" do
    # Each of these erased a sequel name and accepted a different book. They are grouped because
    # they are one mistake in two places: treating unknown text as noise because of where it sits.
    test "a one-word sequel in a trailing bracket is not a tracker tag", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune ({fmt}) (Messiah)"), @dune)

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune ({fmt}) [Messiah]"), @dune)
    end

    test "a real tracker handle after the format is still dropped", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Frank Herbert - Dune ({fmt}) [MyAnonaMouse]"),
                 @dune
               )
    end

    test "a subtitle that restates the requested title is a sequel, not a subtitle", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Frank Herbert - Dune: Children of Dune ({fmt})"),
                 @dune
               )
    end

    test "a genuine descriptive subtitle is still forgiven", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Frank Herbert - Dune: The Story of Paul ({fmt})"),
                 @dune
               )
    end
  end

  describe "works whose titles are collection words" do
    test "a 'Complete Works' request accepts its own release", ctx do
      work = %{title: "Complete Works", authors: ["William Shakespeare"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "William Shakespeare - Complete Works ({fmt})"),
                 work
               )
    end
  end

  describe "contradictory formats" do
    # The contract fails closed on "unknown OR CONTRADICTORY formats". An accepted format beside a
    # rejected one may be a bundle or a mis-tagged scan, and nothing in the name says which.
    test "an accepted format advertised beside a rejected one is refused", ctx do
      assert {:reject, :format_contradictory} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}) ({refused})"),
                 @beloved
               )

      assert {:reject, :format_contradictory} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved [{fmt}/{refused}]"),
                 @beloved
               )
    end

    test "two ACCEPTED formats are a bundle, not a contradiction", ctx do
      preferred = format(ctx, :fmt)

      assert {:accept, %{format: ^preferred}} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}, {alt})"),
                 @beloved
               )

      assert {:accept, %{format: ^preferred}} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}) ({alt})"),
                 @beloved
               )
    end
  end

  describe "author evidence" do
    test "requires the author's tokens to be present", ctx do
      assert {:reject, :author_mismatch} =
               BookScorer.evaluate(release(ctx, "Someone Else - Beloved ({fmt})"), @beloved)
    end

    test "matches regardless of name order", ctx do
      work = %{title: "The Three-Body Problem", authors: ["Cixin Liu"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Liu Cixin - The Three-Body Problem ({fmt})"),
                 work
               )
    end

    test "matches across diacritics and punctuation", ctx do
      work = %{title: "Les Miserables", authors: ["Victor Hugo"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Victor Hugo - Les Misérables ({fmt})"), work)
    end

    test "a work with no known author cannot be matched", ctx do
      assert {:reject, :author_mismatch} =
               BookScorer.evaluate(release(ctx, "Anon - Beloved ({fmt})"), %{
                 title: "Beloved",
                 authors: []
               })
    end
  end

  describe "title evidence" do
    test "rejects a different work by the same author", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Song of Solomon ({fmt})"),
                 @beloved
               )
    end

    test "tolerates series, year, and group noise around the title", ctx do
      # The series must be LOADED for its name to be discountable — an unrecognized bracket group
      # is title evidence, not noise. `Books.normalize/1` supplies this from series_memberships.
      work = Map.put(@dispossessed, :series, ["Hainish Cycle"])

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Ursula K. Le Guin - The Dispossessed (Hainish Cycle) (1974) ({fmt})"
                 ),
                 work
               )
    end

    test "an unknown bracketed group is title evidence, not noise", ctx do
      # Dropping every bracketed group unconditionally made brackets a bypass: "Dune (Messiah)"
      # erased to "Dune" and was accepted for a request for Dune.
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune (Messiah) ({fmt})"), @dune)

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune [Messiah] ({fmt})"), @dune)
    end

    test "a trailing tracker tag after the format is still dropped", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}) [MyAnonaMouse]"),
                 @beloved
               )
    end

    test "a colon does not license a sequel name as a subtitle", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune: Messiah ({fmt})"), @dune)
    end

    test "tolerates a missing leading article", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Ursula K. Le Guin - Dispossessed ({fmt})"),
                 @dispossessed
               )
    end

    # The wrong-work family that plain title CONTAINMENT accepts. Each of these carries every token
    # of the requested title and is a different book, so they are the reason `check_title/2` bounds
    # the remainder instead of only testing containment. Found by probing the first implementation,
    # which accepted all four.
    test "rejects a sequel whose name contains the requested title", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune Messiah ({fmt})"), @dune)
    end

    test "rejects a companion work whose name contains the requested title", ctx do
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Frank Herbert - The Dune Encyclopedia ({fmt})"),
                 @dune
               )
    end

    test "rejects a superset title that only appends one word", ctx do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Brandon Sanderson - The Way of Kings Prime ({fmt})"),
                 work
               )
    end

    test "rejects a different work whose name embeds a short requested title", ctx do
      work = %{title: "It", authors: ["Stephen King"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Stephen King - It Chapter Two Companion ({fmt})"),
                 work
               )
    end

    # The other half of the trade: the remainder bound must not reject the shapes real indexers
    # actually publish. Each of these was rejected by the first bounded implementation.
    test "accepts a dot-separated scene name with a year and a group tag", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Frank.Herbert-Dune.2019.Retail.{fmt}.{word}-BitBook"),
                 @dune
               )
    end

    test "accepts a release naming the work's subtitle when the request did not", ctx do
      work = %{title: "Sapiens", authors: ["Yuval Noah Harari"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Yuval Noah Harari - Sapiens: A Brief History of Humankind ({fmt})"
                 ),
                 work
               )
    end

    test "accepts a series-numbered release when the work carries that series", ctx do
      work = %{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        series: ["The Stormlight Archive"]
      }

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings ({fmt})"
                 ),
                 work
               )
    end

    test "a loaded series does not admit a different book in the same series", ctx do
      work = %{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        series: ["The Stormlight Archive"]
      }

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Brandon Sanderson - The Stormlight Archive 02 - Words of Radiance ({fmt})"
                 ),
                 work
               )
    end

    test "accepts a wanted title whose own number is a release-side bare digit", ctx do
      # `strip_noise/2` used to strip EVERY standalone 1-3 digit token as series-position noise,
      # including one the wanted title itself needs -- the exact defect #517 describes.
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Ray Bradbury - Fahrenheit 451 ({fmt})"),
                 %{title: "Fahrenheit 451", authors: ["Ray Bradbury"]}
               )

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Joseph Heller - Catch-22 ({fmt})"),
                 %{title: "Catch-22", authors: ["Joseph Heller"]}
               )

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "John Buchan - The 39 Steps ({fmt})"),
                 %{title: "The 39 Steps", authors: ["John Buchan"]}
               )
    end

    test "a different numbered work by the same author is still rejected", ctx do
      # The other direction: preserving the WANTED title's own number must not turn into ignoring
      # numbers altogether. A release naming a different number entirely is still a different book.
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "John Buchan - The 24 Hours ({fmt})"),
                 %{title: "The 39 Steps", authors: ["John Buchan"]}
               )
    end

    test "an author whose name is also the edition abbreviation is not stripped as metadata",
         ctx do
      # Codex review, round 6: "ed" joined the edition-keyword strip list, but "Ed" is also a
      # real first name. A dot-separated release with author "Ed" must not read "Ed" as an
      # edition marker and lose both the author byline and the wanted title's own number.
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Ed.13.{fmt}"), %{title: "13", authors: ["Ed"]})
    end

    test "a leading space does not defeat the author-named-Ed guard", ctx do
      # Codex review, round 7: the guard excluding "ed" at the very start of the string must
      # still hold when the release keeps a leading space before that start.
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, " Ed.13.{fmt}"), %{title: "13", authors: ["Ed"]})
    end

    test "a wanted title that IS a keyword phrase keeps its own number", ctx do
      # Codex review, round 7: "edition"/"book"/"vol" etc keyword stripping must not erase a
      # wanted title that literally IS that phrase, mirroring the eponymous-series fix.
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "X - Edition 13 ({fmt})"), %{
                 title: "Edition 13",
                 authors: ["X"]
               })
    end

    test "a genuine mid-release 'ed N' edition marker is not preserved by digit-value alone",
         ctx do
      # Codex review, round 8: the same eponymous-phrase test the other keywords use was missing
      # for the abbreviated "ed" form -- it only checked whether the digit VALUE appeared
      # anywhere in the wanted title, not whether "ed N" itself forms a run of wanted's tokens.
      # "Ed 13" here is genuine edition metadata for a DIFFERENT "Room", not the requested
      # "Room 13".
      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Room - Ed 13 ({fmt})"), %{
                 title: "Room 13",
                 authors: ["X"]
               })
    end

    test "a series ordinal that coincidentally equals the wanted number is not title evidence",
         ctx do
      # THE regression that matters most for #517: preserving the wanted title's own number must
      # never loosen the title-match guard enough to admit an unrelated book. This release is a
      # DIFFERENT book -- "Room", volume 13 of series "Foo" -- not the requested "Room 13"; its
      # ordinal "13" merely coincides in value with the wanted title's own number. Driven through
      # the public evaluate/3, not a private helper, so it exercises the full title-match guard.
      work = %{title: "Room 13", authors: ["X"], series: ["Foo"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Foo 13 - Room ({fmt})"), work)
    end

    test "a structured series entry (map, not string) does not crash the ordinal check", ctx do
      # Codex review, round 2: `Cinder.Books.Metadata.work/0`'s documented series shape is a list
      # of `%{name:, position:}` maps, not plain strings.
      work = %{title: "Room 13", authors: ["X"], series: [%{name: "Foo", position: "1"}]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Foo 13 - Room ({fmt})"), work)
    end

    test "a series ordinal is recognized across a normalized (dot/underscore) separator", ctx do
      # Codex review, round 2: a scene-style release writes the series name with dots, not the
      # literal spaces the metadata carries -- the same normalization `tokens/1` already applies.
      work = %{title: "Room 13", authors: ["X"], series: ["Foo Bar"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Foo.Bar.13 - Room ({fmt})"), work)
    end

    test "an eponymous series name is preserved as title evidence, only its ordinal is stripped",
         ctx do
      # Codex review, round 2: when the work's own title IS its series name ("Dune"), stripping
      # the whole "Dune 01" match (not just "01") erased the title itself and wrongly rejected a
      # legitimate release.
      work = %{title: "Dune", authors: ["Frank Herbert"], series: ["Dune"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Frank Herbert - Dune 01 ({fmt})"), work)
    end

    test "a series ordinal is recognized despite a diacritic the release keeps", ctx do
      # Codex review, round 3: the pattern is built from the ASCII-folded series name but must
      # still match the release's own accented spelling, not just a pre-folded one.
      work = %{title: "Room 13", authors: ["X"], series: ["Café"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Café.13 - Room ({fmt})"), work)
    end

    test "an edition number that coincidentally equals the wanted number is not title evidence",
         ctx do
      # Codex review, round 4: the same coincidence series ordinals close applies to edition or
      # printing metadata -- "Edition 13" for a DIFFERENT "Room" must not supply the wanted
      # title's own missing "13" just because the digits match.
      work = %{title: "Room 13", authors: ["X"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Room - Edition 13 ({fmt})"), work)
    end

    test "a series ordinal is recognized despite an apostrophe the release keeps", ctx do
      # Codex review, round 4: tokens/1 DROPS apostrophes rather than treating them as
      # separators ("Dragon's" folds to "dragons"), so the ordinal pattern must tolerate one
      # between letters, not just combining marks.
      work = %{title: "Room 13", authors: ["X"], series: ["Dragon's Foo"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Dragon's Foo 13 - Room ({fmt})"), work)
    end

    test "a series ordinal is recognized whether it precedes or follows the series name", ctx do
      # Codex review, round 5: an indexer can write the ordinal before the series name too
      # ("13 Foo"), not only after it ("Foo 13").
      work = %{title: "Room 13", authors: ["X"], series: ["Foo"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - 13 Foo - Room ({fmt})"), work)
    end

    test "a number is preserved when the wanted title itself is the series name plus that number",
         ctx do
      # Codex review, round 6: the wanted title can BE its series name followed by its own
      # number ("Room 13", series "Room") -- unlike the round-1 case (series "Foo" for a wanted
      # "Room 13"), here the series name is genuinely part of the wanted title, so its adjacent
      # number must not be stripped as an unrelated ordinal.
      work = %{title: "Room 13", authors: ["X"], series: ["Room"]}

      assert {:accept, _evidence} = BookScorer.evaluate(release(ctx, "X - Room 13 ({fmt})"), work)
    end

    test "a proper field separator does not attach the next field's number as an ordinal", ctx do
      # Codex review, round 7: "Author - Series - Title" uses a spaced hyphen as a FIELD
      # delimiter, not a tight ordinal separator -- the next field's own leading number
      # ("13 Ways") must not be misread as the series' ordinal just because a loose hyphen
      # sits between them.
      work = %{title: "13 Ways", authors: ["X"], series: [%{name: "Foo", position: "1"}]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "X - Foo - 13 Ways ({fmt})"), work)
    end

    test "a digit embedded in the series name itself is not preserved for an unrelated title",
         ctx do
      # Codex review, round 7: the series name can itself embed a number ("Foo 13") that
      # coincides with the wanted title's own digit while naming a completely different work.
      work = %{title: "Room 13", authors: ["X"], series: ["Foo 13"]}

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X - Foo 13 - Room ({fmt})"), work)
    end

    test "a fractional series ordinal is consumed as one unit, not left partly exposed", ctx do
      # Codex review, round 8: a series position can be a decimal ("1.5", a novella between
      # books 1 and 2). Matching only the integer prefix left the fractional remainder exposed
      # as a coincidentally-matching bare digit for an unrelated wanted title.
      work = %{
        title: "Room 5",
        authors: ["X"],
        series: [%{name: "Foo", position: "1.5"}]
      }

      assert {:reject, :title_mismatch} =
               BookScorer.evaluate(release(ctx, "X.Foo.1.5.Room.{fmt}"), work)
    end
  end

  describe "protocol" do
    test "rejects a release whose protocol has no configured client", ctx do
      release = release(ctx, "Toni Morrison - Beloved ({fmt})", protocol: :usenet)

      assert {:reject, :wrong_protocol} =
               BookScorer.evaluate(release, @beloved, protocols: [:torrent])
    end

    test "accepts the same release when its protocol is configured", ctx do
      release = release(ctx, "Toni Morrison - Beloved ({fmt})", protocol: :usenet)
      assert {:accept, _evidence} = BookScorer.evaluate(release, @beloved, protocols: [:usenet])
    end

    test "no protocols option means no gate", ctx do
      release = release(ctx, "Toni Morrison - Beloved ({fmt})", protocol: :usenet)
      assert {:accept, _evidence} = BookScorer.evaluate(release, @beloved)
    end
  end

  describe "unfoldable titles" do
    # Folding to ASCII DISCARDS non-Latin script, so two different works can share their Latin
    # residue. `Cinder.Books.Identity` refuses these for the same reason; the scorer must not be
    # the weaker gate.
    test "a non-Latin title is refused rather than compared on its Latin residue", ctx do
      work = %{title: "ノルウェイの森 1", authors: ["Haruki Murakami"]}

      assert {:reject, :title_unfoldable} =
               BookScorer.evaluate(release(ctx, "Haruki Murakami - 海辺のカフカ 1 ({fmt})"), work)
    end

    test "a non-Latin release name cannot satisfy a Latin-titled work", ctx do
      work = %{title: "Norwegian Wood", authors: ["Haruki Murakami"]}

      assert {:reject, :title_unfoldable} =
               BookScorer.evaluate(release(ctx, "Haruki Murakami - 海辺のカフカ ({fmt})"), work)
    end

    test "diacritics are not lossy — accented Latin still compares", ctx do
      work = %{title: "Les Misérables", authors: ["Victor Hugo"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Victor Hugo - Les Miserables ({fmt})"), work)
    end
  end

  describe "collection ambiguity" do
    test "an omnibus containing the requested title is refused with its own reason", ctx do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Brandon Sanderson - Stormlight Archive Books 1-3 (The Way of Kings, Words of Radiance, Oathbringer) ({fmt})"
                 ),
                 work
               )
    end

    test "the single volume of the same series is accepted", ctx do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Brandon Sanderson - The Way of Kings ({fmt})"),
                 work
               )
    end

    # A work whose OWN title carries a collection word is an ordinary request, not an ambiguity.
    # An unconditional reject made every one of these permanently unrequestable, with a reason that
    # blamed the release for saying what the work is called.
    test "a work whose own title is an anthology can still be requested", ctx do
      work = %{title: "The Norton Anthology of Poetry", authors: ["Margaret Ferguson"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Margaret Ferguson - The Norton Anthology of Poetry ({fmt})"),
                 work
               )
    end

    test "a work whose own title contains 'Collection' can still be requested", ctx do
      work = %{title: "Collection Agency", authors: ["Some Author"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Some Author - Collection Agency ({fmt})"), work)
    end

    test "a pack still refuses when the request never mentioned a collection", ctx do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(
                   ctx,
                   "Brandon Sanderson - The Way of Kings (Stormlight Omnibus) ({fmt})"
                 ),
                 work
               )
    end

    # #518: the bare numeric-range regex ("11-22-63") has no keyword, so it cannot tell a
    # collection span from a numeric title's own number written as a range -- fixed here so the
    # release no longer fails at the COLLECTION gate. Full acceptance also needed #517's
    # wanted-number preservation in `check_title/2`; both are merged now, so the release is fully
    # accepted rather than merely clearing one gate.
    test "a numeric title matching the release's own bare range is fully accepted", ctx do
      work = %{title: "11/22/63", authors: ["Stephen King"]}

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Stephen King - 11-22-63 ({fmt})"), work)
    end

    # The other direction: a bare numeric range that does NOT match the wanted title's own digits
    # is still a genuine, unexplained collection claim and must still be refused.
    test "a bare numeric range unrelated to the wanted title is still refused", ctx do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(ctx, "Brandon Sanderson - The Way of Kings 1-3 ({fmt})"),
                 work
               )
    end

    test "an explicit hash-range pack is refused even when its digits match the wanted title",
         ctx do
      # Codex review: "#1-3" is explicit volume/issue notation, unconditional evidence of a pack,
      # regardless of whether the wanted title happens to share those digits.
      work = %{title: "Numeric Work 1/3", authors: ["Author Name"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(ctx, "Author Name - Numeric Work 1/3 #1-3 ({fmt})"),
                 work
               )
    end

    test "a bare pack range redundant with the wanted title's own number is still refused", ctx do
      # Codex review, round 2: the release restates the wanted number ONCE as its own title
      # ("1/3") and a SECOND time as a genuinely separate bare-range pack marker ("1-3"). A real
      # numeric title needs its number only once; the second occurrence is unexplained.
      work = %{title: "Numeric Work 1/3", authors: ["Author Name"]}

      assert {:reject, :collection_ambiguous} =
               BookScorer.evaluate(
                 release(ctx, "Author Name - Numeric Work 1/3 1-3 ({fmt})"),
                 work
               )
    end
  end

  describe "language" do
    test "no requested language means no gate", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})"),
                 @beloved
               )
    end

    test "an untagged release satisfies an ENGLISH request only", ctx do
      # Untagged means English by scene convention, so it satisfies English and nothing else.
      # Passing every request handed a household asking for French an almost-certainly-English
      # file — the same fail-open `Cinder.Acquisition.Language` closed for video.
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved,
                 language: "en"
               )

      assert {:reject, :language_mismatch} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved,
                 language: "fr"
               )
    end

    test "a three-letter ISO 639-2 code matches the parser's tag", ctx do
      # Open Library publishes `/languages/eng`, so a caller passing `edition.language` straight
      # through supplies "eng" — which upcased to "ENG" and matched no tag the parser emits,
      # rejecting a correctly-tagged English release as the wrong language.
      for code <- ["eng", "en"] do
        assert {:accept, %{language: "ENGLISH"}} =
                 BookScorer.evaluate(
                   release(ctx, "Toni Morrison - Beloved [ENGLISH] ({fmt})"),
                   @beloved,
                   language: code
                 ),
               "#{code} did not match ENGLISH"
      end

      for code <- ["fre", "fra", "fr"] do
        assert {:accept, %{language: "FRENCH"}} =
                 BookScorer.evaluate(
                   release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})"),
                   @beloved,
                   language: code
                 ),
               "#{code} did not match FRENCH"
      end
    end

    test "a contradicting language is rejected", ctx do
      assert {:reject, :language_mismatch} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})"),
                 @beloved,
                 language: "en"
               )
    end

    test "a matching language is accepted by ISO code", ctx do
      assert {:accept, %{language: "FRENCH"}} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})"),
                 @beloved,
                 language: "fr"
               )
    end

    test "MULTI satisfies any requested language", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}) [MULTI]"),
                 @beloved,
                 language: "fr"
               )
    end
  end

  describe "abridgement" do
    # An abridged text is a DIFFERENT text. The contract groups abridged/unabridged ambiguity with
    # omnibus and anthology and requires an explained rejection.
    test "an abridged release is refused with its own reason", ctx do
      assert {:reject, :abridged_edition} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved Abridged ({fmt})"),
                 @beloved
               )

      assert {:reject, :abridged_edition} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved (Abridged) ({fmt})"),
                 @beloved
               )
    end

    test "'unabridged' is not read as 'abridged'", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved Unabridged ({fmt})"),
                 @beloved
               )
    end

    test "a request that explicitly wants the abridged edition accepts one", ctx do
      work = Map.put(@beloved, :abridged, true)

      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved Abridged ({fmt})"), work)
    end
  end

  describe "size band" do
    test "rejects a stub below the floor", ctx do
      assert {:reject, :size_out_of_band} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})", size: 1_000),
                 @beloved
               )
    end

    test "rejects a pack above the kind's ceiling", ctx do
      {_min, max} = BookKind.size_band(ctx.kind)

      assert {:reject, :size_out_of_band} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})", size: max + 1),
                 @beloved
               )
    end

    test "the band is inclusive at both edges", ctx do
      {min, max} = BookKind.size_band(ctx.kind)

      for size <- [min, max] do
        assert {:accept, _evidence} =
                 BookScorer.evaluate(
                   release(ctx, "Toni Morrison - Beloved ({fmt})", size: size),
                   @beloved
                 ),
               "#{size} bytes was refused"
      end

      assert {:reject, :size_out_of_band} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})", size: min - 1),
                 @beloved
               )
    end

    test "an unreported size passes rather than filtering out the whole indexer", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})", size: nil),
                 @beloved
               )
    end
  end

  describe "blocked terms" do
    test "a blocked substring rejects the release", ctx do
      assert {:reject, :blocked_term} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt}) [SAMPLE]"),
                 @beloved,
                 blocked_terms: ["sample"]
               )
    end

    test "a blank blocked term matches nothing", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved,
                 blocked_terms: ["", "   "]
               )
    end
  end

  describe "release blocklist" do
    test "rejects a title proven bad for this target even when every other check would accept it",
         ctx do
      assert {:reject, :blocklisted} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})"),
                 @beloved,
                 release_blocklist: [name(ctx, "Toni Morrison - Beloved ({fmt})")]
               )
    end

    test "matches case-insensitively", ctx do
      assert {:reject, :blocklisted} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})"),
                 @beloved,
                 release_blocklist: [String.upcase(name(ctx, "Toni Morrison - Beloved ({fmt})"))]
               )
    end

    test "an unrelated blocklist entry does not reject a different title", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(
                 release(ctx, "Toni Morrison - Beloved ({fmt})"),
                 @beloved,
                 release_blocklist: [name(ctx, "Some Other Release ({fmt})")]
               )
    end

    test "an empty blocklist rejects nothing", ctx do
      assert {:accept, _evidence} =
               BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved,
                 release_blocklist: []
               )
    end
  end

  describe "evaluate_all/3" do
    test "ranks accepted releases and explains every rejection", ctx do
      releases = [
        release(ctx, "Toni Morrison - Beloved ({alt})", size: size(ctx, 1)),
        release(ctx, "Toni Morrison - Beloved ({refused})", size: size(ctx, 1)),
        release(ctx, "Toni Morrison - Beloved ({fmt})", size: size(ctx, 2.5)),
        release(ctx, "Toni Morrison - Beloved ({fmt}) [retail]", size: size(ctx, 3)),
        release(ctx, "Someone Else - Beloved ({fmt})", size: size(ctx, 1))
      ]

      %{accepted: accepted, rejected: rejected} = BookScorer.evaluate_all(releases, @beloved)

      assert [first, second, third] = Enum.map(accepted, fn {release, _e} -> release.title end)
      # The preferred format outranks the second one; retail outranks non-retail within the same
      # format, even when the retail file is larger.
      assert first == name(ctx, "Toni Morrison - Beloved ({fmt}) [retail]")
      assert second == name(ctx, "Toni Morrison - Beloved ({fmt})")
      assert third == name(ctx, "Toni Morrison - Beloved ({alt})")

      assert Enum.sort(Enum.map(rejected, fn {_release, reason} -> reason end)) ==
               [:author_mismatch, :format_rejected]
    end

    test "prefers the smaller file among otherwise equal candidates", ctx do
      # Distinguished by tracker tag, not by a bare letter: a one-letter bracket group is not a
      # recognizable tracker handle, and unknown bracket content is title evidence now.
      releases = [
        release(ctx, "Toni Morrison - Beloved ({fmt}) [Tracker1]", size: size(ctx, 20)),
        release(ctx, "Toni Morrison - Beloved ({fmt}) [Tracker2]", size: size(ctx, 1.5))
      ]

      %{accepted: [{best, _evidence} | _rest]} = BookScorer.evaluate_all(releases, @beloved)

      assert best.size == size(ctx, 1.5)
    end

    test "an untagged release outranks a foreign-tagged one when no language is asked for", ctx do
      # Being tagged at all must not be a promotion: an untagged book release is overwhelmingly
      # English, so a [FRENCH] copy sorting first handed the household the wrong language.
      releases = [
        release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})"),
        release(ctx, "Toni Morrison - Beloved ({fmt})")
      ]

      %{accepted: accepted} = BookScorer.evaluate_all(releases, @beloved)

      assert Enum.map(accepted, fn {release, _evidence} -> release.title end) == [
               name(ctx, "Toni Morrison - Beloved ({fmt})"),
               name(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})")
             ]
    end

    test "a non-English request drops the untagged release rather than ranking it", ctx do
      # An untagged release is English by convention, so it satisfies an English request and
      # nothing else — it is rejected here, not merely out-ranked.
      releases = [
        release(ctx, "Toni Morrison - Beloved ({fmt})"),
        release(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})")
      ]

      %{accepted: accepted, rejected: rejected} =
        BookScorer.evaluate_all(releases, @beloved, language: "fr")

      assert Enum.map(accepted, fn {release, _evidence} -> release.title end) ==
               [name(ctx, "Toni Morrison - Beloved [FRENCH] ({fmt})")]

      assert [{_release, :language_mismatch}] = rejected
    end

    test "returns empty lists for no input" do
      assert %{accepted: [], rejected: []} = BookScorer.evaluate_all([], @beloved)
    end
  end

  # The claim this file previously made — that comparing `reasons/0` to a hand-copied third list
  # here proved it was "every reject reason `evaluate/3` can return" — was false: a hardcoded
  # comparison list can drift from `evaluate/3`'s real behavior exactly like the two lists it
  # replaced could drift from each other (`@type reason` and `reasons/0` are now generated from
  # one `@reasons` attribute in `book_scorer.ex`, closing that half of the gap). This proves the
  # other half: every atom `reasons/0` declares is independently reachable through a real
  # `evaluate/3` call, via a fixture already exercised by its own dedicated test elsewhere in this
  # file — and the reverse, that every fixture below still names a real declared reason, so a
  # reason removed from `@reasons` and forgotten here fails too.
  test "every BookScorer.reasons/0 atom is genuinely reachable from evaluate/3", ctx do
    triggers = %{
      format_unknown: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved"), @beloved)
      end,
      format_rejected: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({refused})"), @beloved)
      end,
      format_contradictory: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt}) ({refused})"), @beloved)
      end,
      author_mismatch: fn ->
        BookScorer.evaluate(release(ctx, "Someone Else - Beloved ({fmt})"), @beloved)
      end,
      title_mismatch: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Song of Solomon ({fmt})"), @beloved)
      end,
      title_unfoldable: fn ->
        work = %{title: "ノルウェイの森 1", authors: ["Haruki Murakami"]}
        BookScorer.evaluate(release(ctx, "Haruki Murakami - 海辺のカフカ 1 ({fmt})"), work)
      end,
      language_mismatch: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved ({fmt})"), @beloved,
          language: "fr"
        )
      end,
      wrong_protocol: fn ->
        BookScorer.evaluate(
          release(ctx, "Toni Morrison - Beloved ({fmt})", protocol: :usenet),
          @beloved,
          protocols: [:torrent]
        )
      end,
      abridged_edition: fn ->
        BookScorer.evaluate(release(ctx, "Toni Morrison - Beloved Abridged ({fmt})"), @beloved)
      end,
      collection_ambiguous: fn ->
        work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

        BookScorer.evaluate(
          release(
            ctx,
            "Brandon Sanderson - Stormlight Archive Books 1-3 " <>
              "(The Way of Kings, Words of Radiance, Oathbringer) ({fmt})"
          ),
          work
        )
      end,
      size_out_of_band: fn ->
        BookScorer.evaluate(
          release(ctx, "Toni Morrison - Beloved ({fmt})", size: 1_000),
          @beloved
        )
      end,
      blocked_term: fn ->
        BookScorer.evaluate(
          release(ctx, "Toni Morrison - Beloved ({fmt}) [SAMPLE]"),
          @beloved,
          blocked_terms: ["sample"]
        )
      end,
      blocklisted: fn ->
        BookScorer.evaluate(
          release(ctx, "Toni Morrison - Beloved ({fmt})"),
          @beloved,
          release_blocklist: [String.downcase(name(ctx, "Toni Morrison - Beloved ({fmt})"))]
        )
      end
    }

    assert triggers |> Map.keys() |> Enum.sort() == Enum.sort(BookScorer.reasons())

    for reason <- BookScorer.reasons() do
      assert {:reject, ^reason} = triggers[reason].(),
             "#{inspect(reason)}'s fixture did not trigger it"
    end
  end
end
