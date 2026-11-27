defmodule Cinder.Acquisition.ReleaseProvenanceTest do
  # The indexer provenance each release struct carries (#1644): the source, name and credentials
  # version `new/1` copies from the indexer map, the Prowlarr default for a map with no source, the
  # link `inspect/1` leaves out, `Release.put_provenance/2`, and `Release.per_indexer_rows/3`, which
  # each per-indexer merge uses.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{AudiobookRelease, EbookRelease, Release}

  @structs [
    {Release, "Show.S01E01.1080p.WEB-DL-GRP"},
    {EbookRelease, "Ursula K. Le Guin - The Dispossessed (EPUB)"},
    {AudiobookRelease, "Ursula K. Le Guin - The Dispossessed (M4B)"}
  ]

  for {module, title} <- @structs do
    @module module
    @title title

    describe inspect(module) do
      test "new/1 copies the indexer's source, name and credentials version" do
        release =
          @module.new(%{
            title: @title,
            indexer_id: 4,
            indexer_source: "native",
            indexer_name: "NZBgeek",
            credentials_version: 3
          })

        assert {release.indexer_id, release.indexer_source, release.indexer_name,
                release.credentials_version} == {4, "native", "NZBgeek", 3}
      end

      test "new/1 reads an absent or nil indexer source as Prowlarr's" do
        assert @module.new(%{title: @title}).indexer_source == "prowlarr"
        assert @module.new(%{title: @title, indexer_source: nil}).indexer_source == "prowlarr"

        release = @module.new(%{title: @title})
        assert {release.indexer_name, release.credentials_version} == {nil, nil}
      end

      test "inspect/1 leaves out the download link" do
        link = "https://idx.example/get?apikey=SECRETKEY1"
        release = @module.new(%{title: @title, download_url: link})

        assert release.download_url == link
        assert inspect(release) =~ @title
        refute inspect(release, limit: :infinity, printable_limit: :infinity) =~ "SECRETKEY1"
        assert release == @module.new(%{title: @title, download_url: link})
        refute release == @module.new(%{title: @title, download_url: link <> "2"})
      end
    end
  end

  for {module, title} <- Enum.drop(@structs, 1) do
    @module module
    @title title

    test "from_book/1 builds a #{inspect(module)}'s grab release with its link and provenance" do
      book =
        @module.new(%{
          title: @title,
          size: 7,
          download_url: "https://idx.example/get?apikey=SECRETKEY1",
          download_url_origin: "https://idx.example",
          protocol: :usenet,
          indexer_id: 5,
          indexer_source: "native",
          indexer_name: "Five",
          credentials_version: 2,
          query_origins: [:free_text]
        })

      assert Release.from_book(book) == %Release{
               title: @title,
               size: 7,
               download_url: "https://idx.example/get?apikey=SECRETKEY1",
               download_url_origin: "https://idx.example",
               protocol: :usenet,
               indexer_id: 5,
               indexer_source: "native",
               indexer_name: "Five",
               credentials_version: 2
             }
    end
  end

  describe "put_provenance/2" do
    @copy %{
      indexer_id: 2,
      indexer_source: "native",
      indexer_name: "Two",
      download_url_origin: "https://two.example",
      credentials_version: 9,
      title: "Copy.Title",
      size: 5,
      query_origins: [:free_text]
    }

    test "puts each of the copy's five provenance fields on a struct and keeps the rest" do
      merged =
        Release.new(%{
          title: "Merged.Title",
          size: 10,
          download_url: "magnet:?xt=urn:btih:shared",
          download_url_origin: "https://one.example",
          indexer_id: 1,
          indexer_name: "One",
          credentials_version: 1,
          query_origins: [:id_scoped, :free_text]
        })

      assert Release.put_provenance(merged, @copy) == %{
               merged
               | indexer_id: 2,
                 indexer_source: "native",
                 indexer_name: "Two",
                 download_url_origin: "https://two.example",
                 credentials_version: 9
             }
    end

    test "puts each of the copy's five provenance fields on a plain map and keeps the rest" do
      merged = %{
        title: "Merged.Title",
        size: 10,
        indexer_id: 1,
        indexer_source: "prowlarr",
        indexer_name: "One",
        download_url_origin: "https://one.example",
        credentials_version: 1,
        query_origins: [:id_scoped, :free_text]
      }

      assert Release.put_provenance(merged, @copy) == %{
               title: "Merged.Title",
               size: 10,
               indexer_id: 2,
               indexer_source: "native",
               indexer_name: "Two",
               download_url_origin: "https://two.example",
               credentials_version: 9,
               query_origins: [:id_scoped, :free_text]
             }
    end

    test "on a plain map, a field the copy lacks is left as the merged copy has it" do
      merged = %{title: "Merged.Title", indexer_id: 1, indexer_name: "One"}
      copy = %{title: "Copy.Title", indexer_id: 2}

      assert Release.put_provenance(merged, copy) ==
               %{title: "Merged.Title", indexer_id: 2, indexer_name: "One"}
    end
  end

  describe "per_indexer_rows/3" do
    defp copy(link, source, id, name),
      do: %{link: link, indexer_source: source, indexer_id: id, indexer_name: name}

    defp rows(copies) do
      merged = Map.new(copies, &{&1.link, %{link: &1.link, merged: true}})

      copies
      |> Release.per_indexer_rows(& &1.link, merged)
      |> Enum.map(&{&1.link, &1.merged, &1.indexer_source, &1.indexer_id, &1.indexer_name})
    end

    test "keeps the first copy of each link and indexer, in input order, as the merged copy" do
      copies = [
        copy("b", "native", 1, "First"),
        copy("a", "prowlarr", 1, "Prowlarr"),
        copy("b", "native", 1, "Second"),
        copy("b", "prowlarr", 1, "Other source"),
        copy("b", "native", 2, "Other id")
      ]

      assert rows(copies) == [
               {"b", true, "native", 1, "First"},
               {"a", true, "prowlarr", 1, "Prowlarr"},
               {"b", true, "prowlarr", 1, "Other source"},
               {"b", true, "native", 2, "Other id"}
             ]
    end

    test "drops a copy with no indexer id only when its link has a named copy from its source" do
      copies = [
        copy("a", "native", nil, "Folded"),
        copy("a", "native", 3, "Named"),
        copy("a", "prowlarr", nil, "Own source"),
        copy("b", "native", nil, "Alone")
      ]

      assert rows(copies) == [
               {"a", true, "native", 3, "Named"},
               {"a", true, "prowlarr", nil, "Own source"},
               {"b", true, "native", nil, "Alone"}
             ]
    end

    test "reads a plain-map copy with no indexer keys as nil" do
      merged = %{"a" => %{link: "a", merged: true}}

      assert Release.per_indexer_rows([%{link: "a"}, %{link: "a"}], & &1.link, merged) ==
               [%{link: "a", merged: true}]
    end
  end
end
