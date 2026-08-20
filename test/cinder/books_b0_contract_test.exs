defmodule Cinder.BooksB0ContractTest do
  use ExUnit.Case, async: true

  @corpus_path "test/support/fixtures/books/corpus-v1.json"
  @provider_path "test/support/fixtures/books/provider-v1.json"
  @provider_pair_path "test/support/fixtures/books/metadata-provider-pair-v1.json"
  @bookshelf_path "test/support/fixtures/books/bookshelf-api-v1.json"
  @inventory_path "docs/audits/data/bookshelf-inventory-v1.json"
  @provider_decision_path "docs/audits/data/books-provider-decision-v1.json"
  @parity_path "docs/audits/data/books-parity-matrix-v1.json"
  @audit_path "docs/audits/2026-08-20-bookshelf-inventory.md"
  @contract_path "docs/specs/2026-08-20-books-parity-contract.md"
  @generator_path "test/support/books_b0_inventory.py"

  @required_categories ~w(
    long_series
    series_position
    coauthored
    pen_name
    anthology
    translated_or_alternate
    omnibus
    ebook
    audiobook
    conflicting_editions
    multiple_editions
    missing_isbn
    duplicate_title
    unicode_punctuation
    future_release
    already_correct_file
    irreconcilable_identity
  )

  @resolutions ~w(
    resolved_work
    ambiguous_edition
    provider_unavailable
    no_reliable_match
    adopt_existing_file
  )

  @dispositions [
    "required for cutover",
    "required later",
    "already provided by Cinder",
    "deliberately parked"
  ]

  test "B0 artifacts exist" do
    for path <- [
          @corpus_path,
          @provider_path,
          @provider_pair_path,
          @bookshelf_path,
          @inventory_path,
          @provider_decision_path,
          @parity_path,
          @audit_path,
          @contract_path,
          @generator_path
        ] do
      assert File.regular?(path), "missing B0 artifact: #{path}"
    end
  end

  test "the operator-confirmed corpus contains 40 unique and executable public cases" do
    corpus = read_json!(@corpus_path)
    provider = read_json!(@provider_path)
    titles = corpus["titles"]
    provider_by_id = Map.new(provider["cases"], &{&1["id"], &1})

    assert corpus["version"] == 1
    assert corpus["captured_at"] == corpus["operator_confirmation"]["confirmed_at"]
    assert corpus["operator_confirmation"]["confirmed"] == true
    assert corpus["operator_confirmation"]["selection"] == "curated_public_corpus"
    assert length(titles) == 40
    assert Enum.uniq_by(titles, & &1["id"]) == titles
    assert Enum.uniq_by(titles, & &1["query"]) == titles

    observed_categories = titles |> Enum.flat_map(& &1["categories"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(@required_categories), observed_categories)

    for title <- titles do
      assert is_binary(title["id"])
      assert is_binary(title["query"])
      assert is_binary(title["provider_fixture_id"])
      assert title["categories"] != []
      assert is_list(title["expected_contributors"])

      assert %{
               "edition_policy" => edition_policy,
               "expected_release_date" => expected_release_date,
               "has_audiobook" => has_audiobook,
               "has_ebook" => has_ebook,
               "identity_notes" => identity_notes,
               "migration_state" => migration_state,
               "min_contributors" => min_contributors,
               "min_editions" => min_editions,
               "primary_title" => primary_title,
               "provider_outcome" => provider_outcome,
               "resolution" => resolution,
               "work_id" => work_id
             } = title["expect"]

      assert (is_integer(work_id) and work_id > 0) or is_nil(work_id)
      assert is_binary(primary_title) and primary_title != ""
      assert is_integer(min_editions) and min_editions > 0
      assert is_integer(min_contributors) and min_contributors > 0
      assert length(title["expected_contributors"]) == min_contributors
      assert is_boolean(has_ebook)
      assert is_boolean(has_audiobook)
      assert provider_outcome in ["accept", "reject"]
      assert resolution in @resolutions

      assert edition_policy in ~w(any_matching operator_selection_required unresolved existing_file)

      assert is_nil(expected_release_date) or
               match?({:ok, _}, Date.from_iso8601(expected_release_date))

      assert is_list(identity_notes)
      assert migration_state in ["not_present", "already_correct_file"]
    end

    multiple = find_category!(corpus, "multiple_editions")
    assert multiple["expect"]["min_editions"] >= 2

    future = find_category!(corpus, "future_release")

    assert Date.compare(
             Date.from_iso8601!(future["expect"]["expected_release_date"]),
             Date.from_iso8601!(corpus["captured_at"])
           ) == :gt

    irreconcilable = find_category!(corpus, "irreconcilable_identity")
    assert irreconcilable["expect"]["resolution"] in ~w(provider_unavailable no_reliable_match)

    duplicate = find_category!(corpus, "duplicate_title")
    assert duplicate["expect"]["expected_year"] == 1984

    series_case = find_category!(corpus, "series_position")

    assert series_case["expect"]["expected_series"] == %{
             "title" => "The Wheel of Time",
             "position" => "1"
           }

    provider_series =
      provider_by_id[series_case["provider_fixture_id"]]["selected_work"]["series"]

    assert Enum.any?(provider_series, &(&1["title"] == "The Wheel of Time"))
    assert Enum.all?(provider_series, &is_nil(&1["position"]))
    assert series_case["expect"]["identity_notes"] != []

    for category <- ~w(pen_name missing_isbn duplicate_title unicode_punctuation) do
      assert find_category!(corpus, category)["expect"]["identity_notes"] != []
    end
  end

  test "Hardcover fixtures derive identity, edition, contributor, and media assertions from payloads" do
    corpus = read_json!(@corpus_path)
    provider = read_json!(@provider_path)
    cases = provider["cases"]
    by_id = Map.new(cases, &{&1["id"], &1})

    assert provider["version"] == 1
    assert provider["source"]["base_url"] == "https://api.bookinfo.pro"
    assert length(cases) == 40
    assert map_size(by_id) == 40

    for title <- corpus["titles"] do
      fixture = Map.fetch!(by_id, title["provider_fixture_id"])
      expectation = title["expect"]
      work = fixture["selected_work"]
      editions = work["editions"]

      assert fixture["query"] == title["query"]
      assert fixture["expected"] == expectation
      assert is_list(fixture["search_results"]) and fixture["search_results"] != []
      assert is_list(fixture["candidate_errors"])
      assert is_map(work)
      assert is_list(editions)
      assert fixture["observed"]["edition_count"] == length(editions)
      assert fixture["observed"]["has_ebook"] == Enum.any?(editions, &ebook_edition?/1)
      assert fixture["observed"]["has_audiobook"] == Enum.any?(editions, &audiobook_edition?/1)

      title_match = title_match?(work, expectation["primary_title"])

      known_contributor_match =
        contributor_match?(work, title["expected_contributors"], :any)

      all_contributors_match =
        contributor_match?(work, title["expected_contributors"], :all)

      year_match = work_year_match?(work, expectation["expected_year"])

      assert fixture["assessment"]["title_match"] == title_match
      assert fixture["assessment"]["known_contributor_match"] == known_contributor_match
      assert fixture["assessment"]["contributor_match"] == all_contributors_match
      assert fixture["assessment"]["year_match"] == year_match

      if expectation["provider_outcome"] == "accept" do
        assert title_match and known_contributor_match and year_match
        assert fixture["assessment"]["disposition"] == "accept"
        assert work["foreign_id"] == expectation["work_id"]
        assert length(editions) >= expectation["min_editions"]
        assert fixture["observed"]["has_ebook"] == expectation["has_ebook"]
        assert fixture["observed"]["has_audiobook"] == expectation["has_audiobook"]
      else
        refute title_match and known_contributor_match and year_match
        assert fixture["assessment"]["disposition"] == "reject"
        assert expectation["resolution"] in ~w(provider_unavailable no_reliable_match)
      end
    end
  end

  test "Open Library, Google Books, and Hardcover evidence determine the B2 provider set" do
    corpus = read_json!(@corpus_path)
    pair = read_json!(@provider_pair_path)
    hardcover = read_json!(@provider_path)
    decision = read_json!(@provider_decision_path)
    corpus_by_id = Map.new(corpus["titles"], &{&1["id"], &1})
    pair_by_id = Map.new(pair["cases"], &{&1["id"], &1})

    assert pair["version"] == 1
    assert pair["sources"]["open_library"] == "https://openlibrary.org/search.json"
    assert pair["sources"]["google_books"] == "https://www.googleapis.com/books/v1/volumes"
    assert length(pair["cases"]) == 40
    assert map_size(pair_by_id) == 40
    assert Map.keys(pair_by_id) |> MapSet.new() == Map.keys(corpus_by_id) |> MapSet.new()
    assert pair["summary"] == %{"open_library" => 31, "google_fallback" => 0, "unresolved" => 9}
    assert pair["decision"]["sufficient_for_b2"] == false

    for {id, fixture} <- pair_by_id do
      title = Map.fetch!(corpus_by_id, id)
      assert fixture["expected"]["title"] == title["expect"]["primary_title"]
      assert fixture["expected"]["contributors"] == title["expected_contributors"]
      assert fixture["expected"]["year"] == title["expect"]["expected_year"]

      assert Enum.any?(fixture["errors"], fn error ->
               error["provider"] == "google_books" and String.contains?(error["error"], "429")
             end)

      open_reliable =
        Enum.any?(
          fixture["open_library"]["results"],
          &candidate_reliable?(&1, fixture["expected"])
        )

      google_reliable =
        Enum.any?(
          fixture["google_books"]["results"],
          &candidate_reliable?(&1, fixture["expected"])
        )

      assert fixture["open_library"]["reliable"] == open_reliable
      assert fixture["google_books"]["reliable"] == google_reliable

      if open_reliable do
        assert fixture["outcome"] == "open_library"
        assert candidate_reliable?(fixture["open_library"]["selected"], fixture["expected"])
      else
        refute google_reliable
        assert fixture["outcome"] == "unresolved"

        if fixture["open_library"]["results"] == [] do
          assert is_nil(fixture["open_library"]["selected"])
        else
          refute is_nil(fixture["open_library"]["selected"])
        end
      end
    end

    open_library_resolved =
      pair["cases"]
      |> Enum.filter(fn fixture ->
        Enum.any?(
          fixture["open_library"]["results"],
          &candidate_reliable?(&1, fixture["expected"])
        )
      end)
      |> MapSet.new(& &1["id"])

    hardcover_resolved =
      hardcover["cases"]
      |> Enum.filter(fn fixture ->
        work_reliable?(fixture["selected_work"], Map.fetch!(corpus_by_id, fixture["id"]))
      end)
      |> MapSet.new(& &1["id"])

    union = MapSet.union(open_library_resolved, hardcover_resolved)

    unresolved =
      corpus_by_id |> Map.keys() |> MapSet.new() |> MapSet.difference(union) |> Enum.sort()

    google_429 =
      Enum.count(pair["cases"], fn fixture ->
        Enum.any?(fixture["errors"], fn error ->
          error["provider"] == "google_books" and String.contains?(error["error"], "429")
        end)
      end)

    assert MapSet.size(open_library_resolved) == 31
    assert MapSet.size(hardcover_resolved) == 33
    assert MapSet.size(union) == 37
    assert unresolved == ~w(count-monte-cristo leviathan-wakes time-war)
    assert google_429 == 40

    irreconcilable = find_category!(corpus, "irreconcilable_identity")
    assert irreconcilable["id"] in unresolved

    assert decision["measurements"]["google_books_keyless"]["attempts"] == length(pair["cases"])
    assert decision["measurements"]["google_books_keyless"]["http_429"] == google_429
    assert decision["measurements"]["open_library"]["attempts"] == length(pair["cases"])

    assert decision["measurements"]["open_library"]["reliably_resolved"] ==
             MapSet.size(open_library_resolved)

    assert decision["measurements"]["open_library_plus_hardcover"]["reliably_resolved"] ==
             MapSet.size(union)

    assert decision["decision"]["remaining_unresolved_case_ids"] == unresolved

    corpus_size = map_size(corpus_by_id)
    open_coverage = MapSet.size(open_library_resolved) / corpus_size
    union_coverage = MapSet.size(union) / corpus_size
    threshold = decision["decision"]["threshold_ratio"]

    assert_in_delta pair["decision"]["coverage"], open_coverage, 1.0e-9

    assert pair["decision"]["sufficient_for_b2"] ==
             open_coverage >= pair["decision"]["threshold"]

    assert_in_delta decision["measurements"]["open_library"]["coverage"],
                    open_coverage,
                    1.0e-9

    assert_in_delta decision["measurements"]["open_library_plus_hardcover"]["coverage"],
                    union_coverage,
                    1.0e-9

    expected_sufficient = union_coverage >= threshold
    expected_hardcover_required = open_coverage < threshold and expected_sufficient
    assert decision["decision"]["sufficient_for_b2"] == expected_sufficient

    assert decision["decision"]["hardcover_compatible_adapter_required"] ==
             expected_hardcover_required
  end

  test "aggregate inventory freezes counts, policy, monitoring, latency, and provenance" do
    inventory = read_json!(@inventory_path)
    audit = File.read!(@audit_path)

    assert inventory["version"] == 1
    assert inventory["captured_at"] == "2026-08-20"
    assert inventory["privacy"]["raw_inventory_committed"] == false
    assert inventory["capture"]["api"] == "/api/v1"
    assert inventory["capture"]["generator"] == @generator_path

    assert inventory["capture"]["inputs"] == [
             "deployment-v1.json",
             "latency-v1.json",
             "ebooks/*.json",
             "audiobooks/*.json"
           ]

    assert inventory["capture"]["private_snapshot_manifest"]["file_count"] == 32
    assert inventory["capture"]["private_snapshot_manifest"]["sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert audit =~ inventory["capture"]["private_snapshot_manifest"]["sha256"]
    assert audit =~ "python3 test/support/books_b0_inventory.py"
    assert audit =~ "--snapshot-dir /path/to/private/b0-snapshot"

    generator = File.read!(@generator_path)
    assert generator =~ "deployment-v1.json"
    assert generator =~ "latency-v1.json"
    refute generator =~ "d9ee730e5c70326e8e19329417fc37a3e3bed9dd36ae357d59af0863a54172f8"
    refute generator =~ "c21c4134fdb710481ed69db05bf943b0acdbbf60"

    {help, status} = System.cmd("python3", [@generator_path, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert help =~ "--snapshot-dir"
    assert help =~ "--check"

    assert inventory["source"] == %{
             "application" => "pennydreadful/bookshelf:hardcover",
             "application_branch" => "develop",
             "application_version" => "0.4.20.129",
             "image_digest" =>
               "sha256:d9ee730e5c70326e8e19329417fc37a3e3bed9dd36ae357d59af0863a54172f8",
             "image_revision" => "c21c4134fdb710481ed69db05bf943b0acdbbf60",
             "metadata_base_url" => "https://api.bookinfo.pro"
           }

    assert inventory["instances"]["ebooks"] == %{
             "consumer" => "booklore",
             "counts" => %{"authors" => 2, "works" => 842, "editions" => 2391, "files" => 188},
             "download_clients" => %{"torrent" => 1, "usenet" => 1},
             "file_formats" => %{"azw3" => 25, "epub" => 159, "mobi" => 4},
             "import" => %{
               "completed_download_handling" => true,
               "copy_using_hardlinks" => true,
               "minimum_free_space_mb" => 100,
               "rename_books" => false,
               "standard_book_format" =>
                 "{Book Title}/{Author Name} - {Book Title}{ (PartNumber)}"
             },
             "indexers" => %{"torrent" => 3, "usenet" => 3},
             "monitored" => %{"authors" => 2, "editions" => 841, "works" => 842},
             "quality_profiles" => ["eBook"],
             "root_role" => "books"
           }

    assert inventory["instances"]["audiobooks"] == %{
             "consumer" => "audiobookshelf",
             "counts" => %{"authors" => 2, "works" => 170, "editions" => 651, "files" => 1},
             "download_clients" => %{"torrent" => 1, "usenet" => 1},
             "file_formats" => %{"m4b" => 1},
             "import" => %{
               "completed_download_handling" => true,
               "copy_using_hardlinks" => true,
               "minimum_free_space_mb" => 100,
               "rename_books" => false,
               "standard_book_format" =>
                 "{Book Title}/{Author Name} - {Book Title}{ (PartNumber)}"
             },
             "indexers" => %{"torrent" => 3, "usenet" => 3},
             "monitored" => %{"authors" => 1, "editions" => 169, "works" => 1},
             "quality_profiles" => ["Spoken"],
             "root_role" => "audiobooks"
           }

    for metric <- Map.values(inventory["latency_ms"]) do
      assert metric["sample_size"] == 10
      assert metric["successes"] == 10
      assert metric["min_ms"] > 0
      assert metric["p50_ms"] >= metric["min_ms"]
      assert metric["p95_ms"] >= metric["p50_ms"]
      assert metric["max_ms"] >= metric["p95_ms"]
      assert is_binary(metric["method"])
    end
  end

  test "the sanitized Bookshelf fixture is synthetic, private, and referentially consistent" do
    fixture = read_json!(@bookshelf_path)
    responses = fixture["responses"]
    serialized = Jason.encode!(fixture)
    authors = responses["author"]
    books = responses["book"]
    editions = responses["edition"]
    files = responses["bookfile"]
    author_ids = MapSet.new(authors, & &1["id"])
    authors_by_id = Map.new(authors, &{&1["id"], &1})
    book_ids = MapSet.new(books, & &1["id"])
    editions_by_foreign_id = Map.new(editions, &{&1["foreignEditionId"], &1})
    profiles_by_id = Map.new(responses["qualityprofile"], &{&1["id"], &1})

    assert fixture["version"] == 1
    assert fixture["sanitization"]["derived_from_live_api"]
    assert "all activity and release timestamps" in fixture["sanitization"]["remapped"]
    assert "file sizes and aggregate sizes" in fixture["sanitization"]["remapped"]

    assert "ratings, popularity, votes, page counts, and statistics" in fixture["sanitization"][
             "remapped"
           ]

    assert length(authors) == 2
    assert length(books) == 3
    assert length(editions) == 4
    assert length(files) == 4
    assert Enum.all?(responses["rootfolder"], &(&1["freeSpace"] == 1_000_000_000))
    assert Enum.all?(responses["rootfolder"], &(&1["totalSpace"] == 2_000_000_000))
    assert responses["qualityprofile"] != []
    assert is_map(responses["config/naming"])

    for book <- books do
      assert MapSet.member?(author_ids, book["authorId"])
      selected_edition = Map.fetch!(editions_by_foreign_id, book["foreignEditionId"])
      assert selected_edition["bookId"] == book["id"]

      attached_files = Enum.filter(files, &(&1["bookId"] == book["id"]))
      author = Map.fetch!(authors_by_id, book["authorId"])
      assert Enum.all?(attached_files, &(&1["authorId"] == author["id"]))
      assert book["statistics"]["bookFileCount"] == length(attached_files)
      assert book["statistics"]["sizeOnDisk"] == Enum.sum(Enum.map(attached_files, & &1["size"]))

      profile = Map.fetch!(profiles_by_id, author["qualityProfileId"])

      if String.contains?(author["rootFolderPath"], "audiobooks") do
        assert profile["name"] == "Spoken"
        assert audiobook_edition?(%{"format" => selected_edition["format"]})
        assert Enum.all?(attached_files, &(Path.extname(&1["path"]) == ".m4b"))
      else
        assert profile["name"] == "eBook"

        assert ebook_edition?(%{
                 "format" => selected_edition["format"],
                 "is_ebook" => selected_edition["isEbook"]
               })

        assert Enum.all?(attached_files, &(Path.extname(&1["path"]) in ~w(.epub .azw3 .mobi)))
      end
    end

    for edition <- editions do
      assert MapSet.member?(book_ids, edition["bookId"])
      assert edition["releaseDate"] =~ ~r/^200[1-4]-/
      assert edition["pageCount"] in [100, 200, 300, 400]
    end

    for file <- files do
      assert MapSet.member?(book_ids, file["bookId"])
      assert file["path"] =~ "Fixture Work #{file["bookId"]}"
      assert file["size"] in [1024, 2048, 4096, 8192]
      assert file["dateAdded"] =~ ~r/^2000-02-/

      assert file["quality"]["quality"]["name"] ==
               file["path"] |> Path.extname() |> String.trim_leading(".") |> String.upcase()
    end

    for author <- authors do
      author_files = Enum.filter(files, &(&1["authorId"] == author["id"]))
      author_books = Enum.filter(books, &(&1["authorId"] == author["id"]))
      assert author["statistics"]["bookCount"] == length(author_books)
      assert author["statistics"]["bookFileCount"] == length(author_files)
      assert author["statistics"]["sizeOnDisk"] == Enum.sum(Enum.map(author_files, & &1["size"]))
    end

    refute serialized =~ ~r/api[_-]?key/i
    refute serialized =~ ~r/192\.168\./
    refute serialized =~ "/opt/media"
    refute serialized =~ "/media/books"
    refute serialized =~ "/media/audiobooks"
  end

  test "the parity matrix is complete and machine-verifiable" do
    matrix = read_json!(@parity_path)
    contract = File.read!(@contract_path)
    rows = matrix["rows"]
    by_behavior = Map.new(rows, &{&1["behavior"], &1})

    assert matrix["version"] == 1
    assert matrix["dispositions"] == @dispositions
    assert length(rows) >= 15
    assert Enum.uniq_by(rows, & &1["behavior"]) == rows
    assert MapSet.new(Enum.map(rows, & &1["disposition"])) == MapSet.new(@dispositions)

    for row <- rows do
      assert row["disposition"] in @dispositions
      assert is_binary(row["acceptance"]) and row["acceptance"] != ""
      assert is_binary(row["migration_consequence"]) and row["migration_consequence"] != ""
      assert is_binary(row["owner_milestone"]) and row["owner_milestone"] != ""
    end

    assert contract =~ "books-parity-matrix-v1.json"
    assert contract =~ "normative, machine-readable matrix"

    assert by_behavior["audiobook target and Spoken profile"]["disposition"] == "required later"
    assert by_behavior["audiobook target and Spoken profile"]["owner_milestone"] == "B7"

    assert by_behavior["Audiobookshelf filesystem and scan handoff"]["disposition"] ==
             "required later"

    assert by_behavior["Audiobookshelf filesystem and scan handoff"]["owner_milestone"] == "B7"
    assert by_behavior["automatic author monitoring"]["owner_milestone"] == "B5"
  end

  test "the contract locks B0 decisions and assigns eBook/audio work to B6/B7" do
    contract = File.read!(@contract_path)

    for boundary <- [
          "Author identity and aliases",
          "Work and edition identity",
          "Multiple contributors",
          "Series and position",
          "Monitoring semantics",
          "Quality and format policy",
          "Import naming",
          "Booklore handoff",
          "Audiobookshelf handoff",
          "Migration consequence",
          "Representative metadata/search latency",
          "Metadata provider decision",
          "Parity matrix"
        ] do
      assert contract =~ boundary
    end

    for disposition <- @dispositions, do: assert(contract =~ disposition)

    assert contract =~ "Open Library as primary plus a Hardcover-compatible secondary adapter"
    assert contract =~ "40/40 requests returned HTTP 429"
    assert contract =~ "Preserve release filenames"
    assert contract =~ "many-to-many"
    assert contract =~ "B6 eBook migration"
    assert contract =~ "B7 owns audiobook publication, scan, and migration"
    refute contract =~ "B8 migration"
    assert contract =~ "No books production code may land before B0"
  end

  defp find_category!(corpus, category) do
    Enum.find(corpus["titles"], &(category in &1["categories"])) ||
      flunk("missing corpus category: #{category}")
  end

  defp title_match?(work, expected_title) do
    expected = normalize(expected_title)

    [work["title"] | Enum.map(work["editions"] || [], & &1["title"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize/1)
    |> Enum.member?(expected)
  end

  defp contributor_match?(work, expected_contributors, mode) do
    observed = work["authors"] |> Enum.map(&normalize(&1["name"])) |> MapSet.new()
    matches = Enum.map(expected_contributors, &MapSet.member?(observed, normalize(&1)))

    case mode do
      :any -> Enum.any?(matches)
      :all -> Enum.all?(matches)
    end
  end

  defp candidate_reliable?(candidate, expected) do
    expected_title = normalize(expected["title"])
    candidate_title = normalize(candidate["title"])

    title_match =
      candidate_title == expected_title or
        String.trim_leading(expected_title, "the") == candidate_title

    title_match and
      Enum.any?(expected["contributors"], fn contributor ->
        normalize(contributor) in Enum.map(candidate["contributors"], &normalize/1)
      end) and
      year_match?(
        candidate["first_publish_year"] || candidate["published_date"],
        expected["year"]
      )
  end

  defp work_reliable?(work, corpus_title) do
    title_match?(work, corpus_title["expect"]["primary_title"]) and
      contributor_match?(work, corpus_title["expected_contributors"], :any) and
      work_year_match?(work, corpus_title["expect"]["expected_year"])
  end

  defp work_year_match?(work, expected_year) do
    year_match?(work["release_date"], expected_year)
  end

  defp year_match?(_observed, nil), do: true
  defp year_match?(observed, expected), do: year_from(observed) == expected

  defp year_from(value) when is_integer(value), do: value

  defp year_from(value) when is_binary(value) do
    case Integer.parse(String.slice(value, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp year_from(_value), do: nil

  defp ebook_edition?(edition) do
    edition["is_ebook"] == true or
      Regex.match?(~r/ebook|kindle|nook/i, edition["format"] || "")
  end

  defp audiobook_edition?(edition) do
    Regex.match?(~r/audio|audible/i, edition["format"] || "")
  end

  defp normalize(value) do
    value
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]/u, "")
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
