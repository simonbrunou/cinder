defmodule Cinder.Acquisition.AudiobookScorerTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{AudiobookRelease, AudiobookScorer, BookScorer}

  @beloved %{title: "Beloved", authors: ["Toni Morrison"]}
  @dispossessed %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @dune %{title: "Dune", authors: ["Frank Herbert"]}

  # 100 MB default: comfortably inside the audiobook 5 MB - 8 GB band (§0.1, B7a's own judgment,
  # NOT the contract's), unlike BookScorerTest's 2 MB default which is an e-book-band size.
  defp release(title, attrs \\ []) do
    AudiobookRelease.new(
      Enum.into(attrs, %{
        title: title,
        size: 100_000_000,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent
      })
    )
  end

  describe "format is fail-closed" do
    test "accepts an M4B" do
      assert {:accept, %{format: :m4b}} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B)"), @beloved)
    end

    test "accepts MP3, the other profile format" do
      assert {:accept, %{format: :mp3}} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (MP3)"), @beloved)
    end

    test "an unstated format is rejected rather than assumed" do
      assert {:reject, :format_unknown} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved"), @beloved)
    end

    test "an e-book format is a recognized-but-wrong-family rejection, not unknown" do
      assert {:reject, :format_rejected} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved)
    end

    test "an unsupported audio container is rejected with its own reason" do
      assert {:reject, :format_rejected} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4A)"), @beloved)

      assert {:reject, :format_rejected} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (FLAC)"), @beloved)
    end

    test "a multi-format release is accepted at its best profile format" do
      assert {:accept, %{format: :m4b, formats: formats}} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (MP3, M4B)"), @beloved)

      assert Enum.sort(formats) == [:m4b, :mp3]
    end
  end

  describe "contradictory formats" do
    test "an accepted format advertised beside a rejected one is refused" do
      assert {:reject, :format_contradictory} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B) (M4A)"), @beloved)
    end

    test "two ACCEPTED formats are a bundle, not a contradiction" do
      assert {:accept, %{format: :m4b}} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (m4b, mp3)"), @beloved)
    end
  end

  describe "author evidence" do
    test "requires the author's tokens to be present" do
      assert {:reject, :author_mismatch} =
               AudiobookScorer.evaluate(release("Someone Else - Beloved (M4B)"), @beloved)
    end

    test "matches regardless of name order" do
      work = %{title: "The Three-Body Problem", authors: ["Cixin Liu"]}

      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(release("Liu Cixin - The Three-Body Problem (M4B)"), work)
    end

    test "a work with no known author cannot be matched" do
      assert {:reject, :author_mismatch} =
               AudiobookScorer.evaluate(release("Anon - Beloved (M4B)"), %{
                 title: "Beloved",
                 authors: []
               })
    end
  end

  describe "narrator credit never gates acceptance" do
    test "a release with a matching narrator credit is accepted, and the credit rides in evidence" do
      assert {:accept, %{narrator: "Ray Porter"}} =
               AudiobookScorer.evaluate(
                 release("Andy Weir - Project Hail Mary (Narrated by Ray Porter) (M4B)"),
                 %{title: "Project Hail Mary", authors: ["Andy Weir"]}
               )
    end

    test "the same release is accepted with the SAME reason whether or not it carries a narrator" do
      work = %{title: "Project Hail Mary", authors: ["Andy Weir"]}

      with_narrator =
        AudiobookScorer.evaluate(
          release("Andy Weir - Project Hail Mary (Narrated by Ray Porter) (M4B)"),
          work
        )

      without_narrator =
        AudiobookScorer.evaluate(release("Andy Weir - Project Hail Mary (M4B)"), work)

      assert {:accept, %{narrator: "Ray Porter"}} = with_narrator
      assert {:accept, %{narrator: nil}} = without_narrator
    end

    test "an unrecognized narrator NAME does not produce a title mismatch" do
      # Without narrator-group stripping, "Some Unknown Reader"'s tokens would leak into the
      # title remainder and this would wrongly reject with :title_mismatch.
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Frank Herbert - Dune (Read by Some Unknown Reader) (M4B)"),
                 @dune
               )
    end
  end

  describe "title evidence" do
    test "rejects a different work by the same author" do
      assert {:reject, :title_mismatch} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Song of Solomon (M4B)"),
                 @beloved
               )
    end

    test "rejects a sequel whose name contains the requested title" do
      assert {:reject, :title_mismatch} =
               AudiobookScorer.evaluate(release("Frank Herbert - Dune Messiah (M4B)"), @dune)
    end

    test "tolerates a missing leading article" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Ursula K. Le Guin - Dispossessed (M4B)"),
                 @dispossessed
               )
    end

    test "an unknown bracketed group is title evidence, not noise" do
      assert {:reject, :title_mismatch} =
               AudiobookScorer.evaluate(release("Frank Herbert - Dune (Messiah) (M4B)"), @dune)
    end

    test "a trailing tracker tag after the format is still dropped" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B) [MyAnonaMouse]"),
                 @beloved
               )
    end

    test "accepts a series-numbered release when the work carries that series" do
      work = %{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        series: ["The Stormlight Archive"]
      }

      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release(
                   "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings (M4B)"
                 ),
                 work
               )
    end

    test "accepts a wanted title whose own number is a release-side bare digit" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Ray Bradbury - Fahrenheit 451 (M4B)"),
                 %{title: "Fahrenheit 451", authors: ["Ray Bradbury"]}
               )

      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Joseph Heller - Catch-22 (M4B)"),
                 %{title: "Catch-22", authors: ["Joseph Heller"]}
               )
    end

    test "a different numbered work by the same author is still rejected" do
      assert {:reject, :title_mismatch} =
               AudiobookScorer.evaluate(
                 release("John Buchan - The 24 Hours (M4B)"),
                 %{title: "The 39 Steps", authors: ["John Buchan"]}
               )
    end

    test "a series ordinal that coincidentally equals the wanted number is not title evidence" do
      work = %{title: "Room 13", authors: ["X"], series: ["Foo"]}

      assert {:reject, :title_mismatch} =
               AudiobookScorer.evaluate(release("X - Foo 13 - Room (M4B)"), work)
    end
  end

  describe "unfoldable titles" do
    test "a non-Latin title is refused rather than compared on its Latin residue" do
      work = %{title: "ノルウェイの森 1", authors: ["Haruki Murakami"]}

      assert {:reject, :title_unfoldable} =
               AudiobookScorer.evaluate(
                 release("Haruki Murakami - 海辺のカフカ 1 (M4B)"),
                 work
               )
    end
  end

  describe "collection ambiguity" do
    test "a pack the work did not ask for is refused" do
      work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

      assert {:reject, :collection_ambiguous} =
               AudiobookScorer.evaluate(
                 release(
                   "Brandon Sanderson - Stormlight Archive Books 1-3 " <>
                     "(The Way of Kings, Words of Radiance, Oathbringer) (M4B)"
                 ),
                 work
               )
    end

    test "a work whose own title is a collection word accepts its own release" do
      work = %{title: "Complete Works", authors: ["William Shakespeare"]}

      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("William Shakespeare - Complete Works (M4B)"),
                 work
               )
    end
  end

  describe "language" do
    test "an untagged release satisfies an English request" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B)"), @beloved,
                 language: "en"
               )
    end

    test "an untagged release fails a non-English request" do
      assert {:reject, :language_mismatch} =
               AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B)"), @beloved,
                 language: "fr"
               )
    end

    test "a tagged release must match exactly" do
      assert {:reject, :language_mismatch} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved [FRENCH] (M4B)"),
                 @beloved,
                 language: "en"
               )
    end
  end

  describe "abridgement" do
    test "an abridged release is refused unless the work asks for one" do
      assert {:reject, :abridged_edition} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved Abridged (M4B)"),
                 @beloved
               )
    end

    test "an unabridged release is unaffected by the abridgement gate" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved Unabridged (M4B)"),
                 @beloved
               )
    end
  end

  describe "size band" do
    test "rejects below the 5 MB floor" do
      assert {:reject, :size_out_of_band} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)", size: 1_000_000),
                 @beloved
               )
    end

    test "accepts at the 5 MB floor" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)", size: 5 * 1024 * 1024),
                 @beloved
               )
    end

    test "accepts at the 8 GB ceiling" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)", size: 8 * 1024 * 1024 * 1024),
                 @beloved
               )
    end

    test "rejects above the 8 GB ceiling" do
      assert {:reject, :size_out_of_band} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)", size: 8 * 1024 * 1024 * 1024 + 1),
                 @beloved
               )
    end

    test "a nil size passes the band" do
      assert {:accept, _evidence} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)", size: nil),
                 @beloved
               )
    end
  end

  describe "protocol" do
    test "rejects a release whose protocol has no configured client" do
      release = release("Toni Morrison - Beloved (M4B)", protocol: :usenet)

      assert {:reject, :wrong_protocol} =
               AudiobookScorer.evaluate(release, @beloved, protocols: [:torrent])
    end

    test "no protocols option means no gate" do
      release = release("Toni Morrison - Beloved (M4B)", protocol: :usenet)
      assert {:accept, _evidence} = AudiobookScorer.evaluate(release, @beloved)
    end
  end

  describe "blocked terms" do
    test "rejects a release whose title contains a blocked term" do
      assert {:reject, :blocked_term} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B) [SAMPLE]"),
                 @beloved,
                 blocked_terms: ["sample"]
               )
    end
  end

  describe "release blocklist" do
    test "rejects an exact, case-insensitive blocklisted title before every other check" do
      assert {:reject, :blocklisted} =
               AudiobookScorer.evaluate(
                 release("Toni Morrison - Beloved (M4B)"),
                 @beloved,
                 release_blocklist: ["toni morrison - beloved (m4b)"]
               )
    end
  end

  describe "evaluate_all/3" do
    test "ranks accepted releases and separates rejections" do
      m4b = release("Toni Morrison - Beloved (M4B)")
      mp3 = release("Toni Morrison - Beloved (MP3)")
      wrong = release("Someone Else - Beloved (M4B)")

      assert %{
               accepted: [{first, %{format: :m4b}}, {second, %{format: :mp3}}],
               rejected: rejected
             } =
               AudiobookScorer.evaluate_all([mp3, wrong, m4b], @beloved)

      assert first.title == m4b.title
      assert second.title == mp3.title
      assert Enum.map(rejected, fn {_release, reason} -> reason end) == [:author_mismatch]
    end
  end

  test "accepted_formats/0 is B7a's own judgment: M4B and MP3, M4B first" do
    assert AudiobookScorer.accepted_formats() == [:m4b, :mp3]
  end

  test "size_band/0 is B7a's own judgment: 5 MB - 8 GB" do
    assert AudiobookScorer.size_band() == {5 * 1024 * 1024, 8 * 1024 * 1024 * 1024}
  end

  test "reasons/0 has no duplicates" do
    reasons = AudiobookScorer.reasons()
    assert Enum.sort(reasons) == Enum.sort(Enum.uniq(reasons))
  end

  test "reasons/0 is the identical closed vocabulary BookScorer.reasons/0 already has" do
    assert Enum.sort(AudiobookScorer.reasons()) == Enum.sort(BookScorer.reasons())
  end

  # Same discipline as `BookScorerTest`'s own exhaustiveness test: proves every declared reason is
  # independently reachable through a real `evaluate/3` call, and that nothing here names a reason
  # `reasons/0` no longer declares.
  test "every AudiobookScorer.reasons/0 atom is genuinely reachable from evaluate/3" do
    triggers = %{
      format_unknown: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved"), @beloved)
      end,
      format_rejected: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved (epub)"), @beloved)
      end,
      format_contradictory: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B) (M4A)"), @beloved)
      end,
      author_mismatch: fn ->
        AudiobookScorer.evaluate(release("Someone Else - Beloved (M4B)"), @beloved)
      end,
      title_mismatch: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Song of Solomon (M4B)"), @beloved)
      end,
      title_unfoldable: fn ->
        work = %{title: "ノルウェイの森 1", authors: ["Haruki Murakami"]}
        AudiobookScorer.evaluate(release("Haruki Murakami - 海辺のカフカ 1 (M4B)"), work)
      end,
      language_mismatch: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B)"), @beloved,
          language: "fr"
        )
      end,
      wrong_protocol: fn ->
        AudiobookScorer.evaluate(
          release("Toni Morrison - Beloved (M4B)", protocol: :usenet),
          @beloved,
          protocols: [:torrent]
        )
      end,
      abridged_edition: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved Abridged (M4B)"), @beloved)
      end,
      collection_ambiguous: fn ->
        work = %{title: "The Way of Kings", authors: ["Brandon Sanderson"]}

        AudiobookScorer.evaluate(
          release(
            "Brandon Sanderson - Stormlight Archive Books 1-3 " <>
              "(The Way of Kings, Words of Radiance, Oathbringer) (M4B)"
          ),
          work
        )
      end,
      size_out_of_band: fn ->
        AudiobookScorer.evaluate(release("Toni Morrison - Beloved (M4B)", size: 1_000), @beloved)
      end,
      blocked_term: fn ->
        AudiobookScorer.evaluate(
          release("Toni Morrison - Beloved (M4B) [SAMPLE]"),
          @beloved,
          blocked_terms: ["sample"]
        )
      end,
      blocklisted: fn ->
        AudiobookScorer.evaluate(
          release("Toni Morrison - Beloved (M4B)"),
          @beloved,
          release_blocklist: ["toni morrison - beloved (m4b)"]
        )
      end
    }

    assert triggers |> Map.keys() |> Enum.sort() == Enum.sort(AudiobookScorer.reasons())

    for reason <- AudiobookScorer.reasons() do
      assert {:reject, ^reason} = triggers[reason].(),
             "#{inspect(reason)}'s fixture did not trigger it"
    end
  end
end
