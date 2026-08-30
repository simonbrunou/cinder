defmodule Cinder.Acquisition.Indexer.ProwlarrBookTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Prowlarr

  test "search_book/3 issues a type=book search with brace tokens and the e-book category" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["type"] == "book"
      assert conn.params["query"] == "{Author:Ursula K. Le Guin} {Title:The Dispossessed}"
      assert conn.params["categories"] == "7020"

      Req.Test.json(conn, [
        %{
          "title" => "Ursula K. Le Guin - The Dispossessed (epub)",
          "size" => 1_200_000,
          "downloadUrl" => "http://prowlarr:9696/file/1",
          "protocol" => "torrent",
          "categories" => [%{"id" => 7020}]
        }
      ])
    end)

    assert {:ok, [result]} = Prowlarr.search_book("Ursula K. Le Guin", "The Dispossessed", [])

    assert result.title == "Ursula K. Le Guin - The Dispossessed (epub)"
    assert result.size == 1_200_000
    assert result.download_url == "http://prowlarr:9696/file/1"
    assert result.protocol == :torrent
    assert result.category_ids == [7020]
    assert result.query_origins == [:id_scoped]
  end

  test "search_book/3 sends the title alone when there is no author" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "{Title:Beloved}"
      assert conn.params["type"] == "book"

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_book(nil, "Beloved", [])
  end

  test "braces in an author or title are stripped so a token cannot be truncated" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "{Author:Evil} {Title:Title Genre:horror}"

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_book("Evil}", "Title {Genre:horror}", [])
  end

  test "search_book_query/2 issues a plain text search scoped to the e-book category" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["type"] == "search"
      assert conn.params["query"] == "9780441172719"
      assert conn.params["categories"] == "7020"

      Req.Test.json(conn, [
        %{
          "title" => "Frank Herbert - Dune (epub)",
          "size" => 900_000,
          "downloadUrl" => "http://prowlarr:9696/file/2",
          "protocol" => "usenet"
        }
      ])
    end)

    assert {:ok, [result]} = Prowlarr.search_book_query("9780441172719", [])

    assert result.protocol == :usenet
    assert result.query_origins == [:free_text]
  end

  test "an explicit category list overrides the e-book default" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["categories"] == "7000,7020"

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_book_query("query", categories: [7000, 7020])
  end

  test "a non-200 response is an error, not an empty result" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:prowlarr_status, 500}} = Prowlarr.search_book("Author", "Title", [])
  end

  test "ebook_category/0 is the Books/EBook category, not the Books parent" do
    assert Prowlarr.ebook_category() == 7020
  end
end
