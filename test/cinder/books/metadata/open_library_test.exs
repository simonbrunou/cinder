defmodule Cinder.Books.Metadata.OpenLibraryTest do
  use ExUnit.Case, async: true

  alias Cinder.Books.Metadata.OpenLibrary

  test "search/1 normalizes docs and pairs each author name with its provider key" do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn ->
      assert conn.request_path == "/search.json"
      assert conn.params["q"] == "Beloved Toni Morrison"
      assert conn.params["fields"] =~ "author_key"

      Req.Test.json(conn, %{
        "docs" => [
          %{
            "key" => "/works/OL50548W",
            "title" => "Beloved",
            "author_name" => ["Toni Morrison"],
            "author_key" => ["OL30084A"],
            "first_publish_year" => 1987,
            "edition_count" => 107
          },
          # No work key: identifies nothing, so it is dropped rather than repaired.
          %{"title" => "Beloved", "author_name" => ["Someone"]}
        ]
      })
    end)

    assert {:ok, candidates} = OpenLibrary.search("Beloved Toni Morrison")

    assert candidates == [
             %{
               provider: :openlibrary,
               foreign_id: "OL50548W",
               title: "Beloved",
               contributors: [%{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"}],
               first_published_year: 1987,
               edition_count: 107
             }
           ]
  end

  test "a name with no matching author key is dropped, not invented" do
    stub_search(%{
      "key" => "/works/OL1W",
      "title" => "Work",
      "author_name" => ["Named", "Unidentified"],
      "author_key" => ["OL1A"]
    })

    assert {:ok, [%{contributors: [%{name: "Named"}]}]} = OpenLibrary.search("Work Named")
  end

  test "get_work/1 fetches the work and keeps only digital editions" do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn ->
      case conn.request_path do
        "/search.json" ->
          assert conn.params["q"] == ~s(key:"/works/OL50548W")

          Req.Test.json(conn, %{
            "docs" => [
              %{
                "key" => "/works/OL50548W",
                "title" => "Beloved",
                "author_name" => ["Toni Morrison"],
                "author_key" => ["OL30084A"],
                "first_publish_year" => 1987,
                "edition_count" => 107
              }
            ]
          })

        "/works/OL50548W/editions.json" ->
          Req.Test.json(conn, %{
            "entries" => [
              %{
                "key" => "/books/OL1M",
                "title" => "Beloved",
                "physical_format" => "Paperback",
                "publishers" => ["Vintage"]
              },
              %{
                "key" => "/books/OL2M",
                "title" => "Beloved",
                "physical_format" => "Ebook",
                "languages" => [%{"key" => "/languages/eng"}],
                "publishers" => ["Vintage"],
                "isbn_13" => ["9781400033416"]
              },
              %{
                "key" => "/books/OL3M",
                "title" => "Beloved",
                "physical_format" => "Audio CD"
              }
            ]
          })
      end
    end)

    assert {:ok, work} = OpenLibrary.get_work("OL50548W")
    assert work.foreign_id == "OL50548W"
    assert work.first_published_on == ~D[1987-01-01]
    refute work.contributors_incomplete
    assert work.series == []

    # The paperback has no Cinder media kind and is dropped: `book_editions.media_kind` allows
    # ebook/audiobook only, so there is nowhere for print to land.
    assert [ebook, audiobook] = work.editions
    assert ebook.foreign_id == "OL2M"
    assert ebook.media_kind == :ebook
    assert ebook.language == "eng"
    assert ebook.isbn13 == "9781400033416"
    assert audiobook.media_kind == :audiobook
  end

  test "a work whose payload credits nobody is flagged incomplete rather than filled in" do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn ->
      case conn.request_path do
        "/search.json" ->
          Req.Test.json(conn, %{"docs" => [%{"key" => "/works/OL9W", "title" => "Orphan"}]})

        "/works/OL9W/editions.json" ->
          Req.Test.json(conn, %{"entries" => []})
      end
    end)

    assert {:ok, %{contributors: [], contributors_incomplete: true}} =
             OpenLibrary.get_work("OL9W")
  end

  test "get_work/1 refuses a response that is not the work that was asked for" do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn ->
      Req.Test.json(conn, %{"docs" => [%{"key" => "/works/OTHER", "title" => "Something else"}]})
    end)

    assert {:error, :not_found} = OpenLibrary.get_work("OL50548W")
  end

  test "a non-200, a malformed body, and a transport error each fail without a partial work" do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    assert {:error, {:openlibrary_status, 503}} = OpenLibrary.search("anything")

    Req.Test.stub(Cinder.OpenLibraryStub, fn conn -> Req.Test.json(conn, %{"docs" => "nope"}) end)
    assert {:error, :unexpected_response} = OpenLibrary.search("anything")

    Req.Test.stub(Cinder.OpenLibraryStub, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, _reason} = OpenLibrary.search("anything")
  end

  test "a response past the size cap is refused rather than buffered" do
    oversized = String.duplicate("x", 5 * 1024 * 1024)

    Req.Test.stub(Cinder.OpenLibraryStub, fn conn ->
      Req.Test.json(conn, %{"docs" => [%{"key" => "/works/OL1W", "title" => oversized}]})
    end)

    assert {:error, _reason} = OpenLibrary.search("anything")
  end

  defp stub_search(doc) do
    Req.Test.stub(Cinder.OpenLibraryStub, fn conn -> Req.Test.json(conn, %{"docs" => [doc]}) end)
  end
end
