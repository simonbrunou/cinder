defmodule Cinder.Acquisition.ReleaseJudgeTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{Release, ReleaseJudge}
  alias Cinder.Catalog.Series

  @gb 1_000_000_000

  defp release(title, attrs \\ []) do
    struct(
      %Release{title: title, protocol: :torrent, resolution: "1080p", size: 5 * @gb},
      attrs
    )
  end

  # `Catalog.movie_acquisition_context/1`'s shape.
  defp imdb(title), do: {:imdb, %{title: title, localized_titles: [], aliases: []}}

  defp audio(%ReleaseJudge{rows: rows}),
    do: Map.new(rows, &{&1.release.title, &1.audio})

  defp row(%ReleaseJudge{rows: rows}, title), do: Enum.find(rows, &(&1.release.title == title))

  describe "stages" do
    test "each row names the first stage that drops it, and kept keeps indexer order" do
      releases = [
        release("Film.2021.ENGLISH", language: "ENGLISH"),
        release("Other.Film.Entirely.2021", protocol: :usenet),
        release("Unrelated.2021.FRENCH", language: "FRENCH"),
        release("Film.2021.FRENCH", language: "FRENCH"),
        release("Film.2021.MULTI", language: "MULTI")
      ]

      judged =
        ReleaseJudge.judge(releases, imdb("Film"),
          protocols: [:torrent],
          preferred_language: "french",
          original_language: "en"
        )

      assert Enum.map(releases, &row(judged, &1.title).dropped_at) ==
               [:language, :protocol, :title_guard, nil, nil]

      assert Enum.map(judged.kept, & &1.title) == ["Film.2021.FRENCH", "Film.2021.MULTI"]
      assert judged.language == :applied
    end

    test "with no protocols in the policy, no release is dropped for its protocol" do
      judged = ReleaseJudge.judge([release("Film.2021", protocol: :usenet)], imdb("Film"), [])

      assert [%{dropped_at: nil, verdict: :ok}] = judged.rows
    end

    test "a release with no protocol has no client to go to" do
      judged =
        ReleaseJudge.judge([release("Film.2021", protocol: nil)], imdb("Film"),
          protocols: [:torrent]
        )

      assert [%{dropped_at: :protocol, verdict: {:rejected, :wrong_protocol}}] = judged.rows
    end
  end

  describe "verdicts" do
    # A row with no client can't be grabbed at all, which outranks naming another film.
    test "no client for the protocol outranks a title mismatch, which outranks the rules" do
      judged =
        ReleaseJudge.judge(
          [
            release("Spider.2002.1080p", protocol: :usenet),
            release("Spider.2002.2160p", resolution: "2160p"),
            release("Spiderman.2002.2160p", resolution: "2160p")
          ],
          imdb("Spider-Man"),
          protocols: [:torrent],
          preferred_resolutions: ["1080p"]
        )

      assert row(judged, "Spider.2002.1080p").verdict == {:rejected, :wrong_protocol}
      assert row(judged, "Spider.2002.2160p").verdict == {:rejected, :title_mismatch}
      assert row(judged, "Spiderman.2002.2160p").verdict == {:rejected, :wrong_resolution}
    end

    # The Title.Year and TV guards also reject for a missing or wrong year, or the language
    # before the year, so "title doesn't match" would misstate those rows. They drop silently.
    test "only the IMDb-scoped guard says the title doesn't match" do
      title_year =
        ReleaseJudge.judge(
          [release("Dune.German.2021.1080p", language: "GERMAN")],
          {:title_year, "Dune", 2021},
          []
        )

      assert [%{dropped_at: :title_guard, verdict: :ok}] = title_year.rows

      series =
        ReleaseJudge.judge(
          [release("Darkwing.Duck.S01.1080p", season: 1)],
          {:series, %Series{title: "Dark"}},
          []
        )

      assert [%{dropped_at: :title_guard, verdict: :ok}] = series.rows
    end

    test "a bridged coordinate that resolves two ways can't be judged on its numbers" do
      judged =
        ReleaseJudge.judge(
          [
            release("Show.S02E01.1080p",
              season: 2,
              resolution_evidence: :conflicting_standard_numbering
            )
          ],
          {:series, %Series{title: "Show"}},
          []
        )

      assert [%{verdict: {:rejected, :conflicting_standard_numbering}}] = judged.rows
    end

    test "rows list acceptable releases first, each group in rank order" do
      judged =
        ReleaseJudge.judge(
          [
            release("Film.2021.Huge", size: 90 * @gb),
            release("Film.2021.720p", resolution: "720p"),
            release("Film.2021.1080p")
          ],
          imdb("Film"),
          max_size: 10 * @gb,
          preferred_resolutions: ["1080p", "720p"]
        )

      assert Enum.map(judged.rows, &{&1.release.title, &1.verdict}) == [
               {"Film.2021.1080p", :ok},
               {"Film.2021.720p", :ok},
               {"Film.2021.Huge", {:rejected, :out_of_band}}
             ]
    end
  end

  # What the sweep takes and what the panel shows come from the same record: the pick is the
  # first acceptable row that no stage dropped, ties included.
  describe "pick/1 agrees with the rows" do
    test "the pick is the first acceptable row nobody dropped" do
      policies = [
        [protocols: [:torrent], preferred_language: "original", original_language: "fr"],
        [protocols: [:torrent], preferred_language: "french", original_language: "en"],
        [preferred_language: "any", max_size: 6 * @gb],
        [protocols: [:usenet], preferred_language: "original", original_language: "en"]
      ]

      releases = [
        release("Guru.2025.ENGLISH", language: "ENGLISH", size: 7 * @gb),
        release("Guru.2025.1080p.WEB-FW"),
        release("Guru.2025.FRENCH", language: "FRENCH", protocol: :usenet),
        release("Guru.2025.MULTI", language: "MULTI", resolution: "720p"),
        release("Le.Gourou.2025.FRENCH", language: "FRENCH"),
        release("Guru.2025.1080p.WEB-FW.copy", size: 5 * @gb)
      ]

      for policy <- policies do
        judged = ReleaseJudge.judge(releases, imdb("Guru"), policy)

        expected =
          case Enum.find(judged.rows, &(&1.verdict == :ok and is_nil(&1.dropped_at))) do
            nil -> :no_match
            row -> {:ok, row.release}
          end

        assert ReleaseJudge.pick(judged) == expected, inspect(policy)
      end
    end

    test "a strict pick that empties the pool is no language match, not no match" do
      judged =
        ReleaseJudge.judge([release("M.Only.English", language: "ENGLISH")], imdb("M"),
          preferred_language: "french",
          original_language: "en"
        )

      assert judged.language == :no_language_match
      assert judged.kept == []
      assert ReleaseJudge.pick(judged) == :no_language_match
    end
  end

  # The language badge: what the sweep's language stage decided about each row. `:match` is the
  # release's own tag against the pick and holds at any stage; `:assumed` and `:mismatch` are
  # the pool's verdicts, so only rows that reached the pool carry them.
  describe "audio" do
    test "a strict pick matches its tag and rejects an untagged release" do
      judged =
        ReleaseJudge.judge(
          [release("Le film", language: "FRENCH"), release("The film")],
          imdb("Film"),
          preferred_language: "french",
          original_language: "en"
        )

      assert audio(judged) == %{"Le film" => :match, "The film" => :mismatch}
    end

    # Issue #191: non-English groups publish original audio with a bare name, so the movie pool
    # keeps untagged releases under a soft "original" pick, ranked below a tagged match.
    test "a movie keeps an untagged release under a soft original pick as assumed" do
      judged =
        ReleaseJudge.judge([release("Guru.2025.1080p.WEB.H264-FW")], imdb("Guru"),
          preferred_language: "original",
          original_language: "fr"
        )

      assert audio(judged) == %{"Guru.2025.1080p.WEB.H264-FW" => :assumed}
      assert [_kept] = judged.kept
    end

    # The #191 relaxation is movie-only (ADR 0003, #882): the TV pool never keeps untagged
    # releases.
    test "a TV season drops the untagged release a movie would keep" do
      judged =
        ReleaseJudge.judge(
          [
            release("Serie.S01.FRENCH", language: "FRENCH", season: 1),
            release("Serie.S01.1080p", season: 1)
          ],
          {:series, %Series{title: "Série"}},
          preferred_language: "original",
          original_language: "fr"
        )

      assert audio(judged) == %{"Serie.S01.FRENCH" => :match, "Serie.S01.1080p" => :mismatch}
    end

    # MULTI satisfies any target, so the pool is non-empty and the FRENCH row really is dropped,
    # even for an original language the parser has no tag for.
    test "an unmapped original language still rejects what the pool drops" do
      judged =
        ReleaseJudge.judge(
          [release("Multi", language: "MULTI"), release("Wrong", language: "FRENCH")],
          {:series, %Series{title: "Hérbergið", tvdb_id: 42}},
          preferred_language: "original",
          original_language: "is"
        )

      assert audio(judged) == %{"Multi" => :match, "Wrong" => :mismatch}
    end

    # A soft pick that would drop everything falls back to the unfiltered pool: the sweep then
    # judges nothing on language, so no row is rejected for it.
    test "a soft pick that would drop everything falls back and rejects nothing" do
      releases = [release("One", language: "FRENCH"), release("Two", language: "GERMAN")]

      judged =
        ReleaseJudge.judge(releases, {:series, %Series{title: "Hérbergið", tvdb_id: 42}},
          preferred_language: "original",
          original_language: "is"
        )

      assert judged.language == :fell_back
      assert judged.kept == releases
      assert audio(judged) == %{"One" => nil, "Two" => nil}
      assert Enum.all?(judged.rows, &is_nil(&1.dropped_at))
    end

    # The only release that satisfies the pick has no client, so the pool the language stage
    # sees holds no match and falls back. The English row is not rejected for its audio; the
    # French row is still, factually, French.
    test "a release with no client doesn't count toward the language pool" do
      judged =
        ReleaseJudge.judge(
          [
            release("Guru.2025.FRENCH", protocol: :usenet, language: "FRENCH"),
            release("Guru.2025.ENGLISH", language: "ENGLISH")
          ],
          imdb("Guru"),
          protocols: [:torrent],
          preferred_language: "original",
          original_language: "fr"
        )

      assert judged.language == :fell_back
      assert audio(judged) == %{"Guru.2025.FRENCH" => :match, "Guru.2025.ENGLISH" => nil}
      assert ReleaseJudge.pick(judged) == {:ok, row(judged, "Guru.2025.ENGLISH").release}
    end

    test "a release the title guard drops doesn't count toward the language pool" do
      judged =
        ReleaseJudge.judge(
          [
            release("Le.Guru.Sequel.2021.FRENCH", language: "FRENCH"),
            release("Guru.2021.ENGLISH", language: "ENGLISH")
          ],
          {:title_year, "Guru", 2021},
          preferred_language: "original",
          original_language: "fr"
        )

      assert judged.language == :fell_back

      assert audio(judged) == %{
               "Le.Guru.Sequel.2021.FRENCH" => :match,
               "Guru.2021.ENGLISH" => nil
             }
    end

    test "a row dropped before the language stage is never rejected for its audio" do
      no_client =
        ReleaseJudge.judge(
          [
            release("M.2021.FRENCH", language: "FRENCH"),
            release("M.2021.GERMAN", protocol: :usenet, language: "GERMAN")
          ],
          imdb("M"),
          protocols: [:torrent],
          preferred_language: "french",
          original_language: "en"
        )

      assert audio(no_client) == %{"M.2021.FRENCH" => :match, "M.2021.GERMAN" => nil}

      other_show =
        ReleaseJudge.judge(
          [
            release("Dark.S01.GERMAN", language: "GERMAN", season: 1),
            release("Darkwing.Duck.S01.ENGLISH", language: "ENGLISH", season: 1)
          ],
          {:series, %Series{title: "Dark"}},
          preferred_language: "original",
          original_language: "de"
        )

      assert audio(other_show) == %{
               "Dark.S01.GERMAN" => :match,
               "Darkwing.Duck.S01.ENGLISH" => nil
             }

      other_film =
        ReleaseJudge.judge(
          [
            release("Spider-Man.Brand.New.Day.2026.FRENCH", language: "FRENCH"),
            release("Spider-Island.2026.ENGLISH", language: "ENGLISH")
          ],
          imdb("Spider-Man: Brand New Day"),
          preferred_language: "french",
          original_language: "en"
        )

      assert audio(other_film) == %{
               "Spider-Man.Brand.New.Day.2026.FRENCH" => :match,
               "Spider-Island.2026.ENGLISH" => nil
             }
    end

    # A match is a fact about the release's own tag, so it holds on a row the sweep never
    # scores: the operator switching clients wants to know this one is the French one.
    test "a release with no client that satisfies the pick still matches" do
      judged =
        ReleaseJudge.judge(
          [
            release("M.2021.ENGLISH", language: "ENGLISH"),
            release("M.2021.FRENCH", protocol: :usenet, language: "FRENCH")
          ],
          imdb("M"),
          protocols: [:torrent],
          preferred_language: "french",
          original_language: "en"
        )

      assert audio(judged) == %{"M.2021.ENGLISH" => :mismatch, "M.2021.FRENCH" => :match}
    end

    test "a strict pick that drops everything rejects every row that reached it" do
      judged =
        ReleaseJudge.judge([release("M.Only.English", language: "ENGLISH")], imdb("M"),
          preferred_language: "french",
          original_language: "en"
        )

      assert audio(judged) == %{"M.Only.English" => :mismatch}
    end

    test "with no pick in force, no row carries a language fact" do
      for {preferred, original} <- [{"any", "fr"}, {"original", nil}] do
        judged =
          ReleaseJudge.judge(
            [release("Whatever"), release("Whatever.FRENCH", language: "FRENCH")],
            imdb("Whatever"),
            preferred_language: preferred,
            original_language: original
          )

        assert judged.language == :off
        assert audio(judged) == %{"Whatever" => nil, "Whatever.FRENCH" => nil}
      end
    end
  end
end
