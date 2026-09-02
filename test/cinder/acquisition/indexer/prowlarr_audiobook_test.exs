defmodule Cinder.Acquisition.Indexer.ProwlarrAudiobookTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Prowlarr

  test "search_audiobook/3 issues a type=book search with brace tokens and the audiobook category" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["type"] == "book"
      assert conn.params["query"] == "{Author:Ursula K. Le Guin} {Title:The Dispossessed}"
      assert conn.params["categories"] == "3030"

      Req.Test.json(conn, [
        %{
          "title" => "Ursula K. Le Guin - The Dispossessed (M4B)",
          "size" => 500_000_000,
          "downloadUrl" => "http://prowlarr:9696/file/1",
          "protocol" => "torrent",
          "categories" => [%{"id" => 3030}]
        }
      ])
    end)

    assert {:ok, [result]} =
             Prowlarr.search_audiobook("Ursula K. Le Guin", "The Dispossessed", [])

    assert result.title == "Ursula K. Le Guin - The Dispossessed (M4B)"
    assert result.size == 500_000_000
    assert result.download_url == "http://prowlarr:9696/file/1"
    assert result.protocol == :torrent
    assert result.category_ids == [3030]
    assert result.query_origins == [:id_scoped]
  end

  test "search_audiobook/3 sends the title alone when there is no author" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "{Title:Beloved}"
      assert conn.params["type"] == "book"

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_audiobook(nil, "Beloved", [])
  end

  test "search_audiobook_query/2 issues a plain text search scoped to the audiobook category" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["type"] == "search"
      assert conn.params["query"] == "B000FC0SIM"
      assert conn.params["categories"] == "3030"

      Req.Test.json(conn, [
        %{
          "title" => "Frank Herbert - Dune (M4B)",
          "size" => 700_000_000,
          "downloadUrl" => "http://prowlarr:9696/file/2",
          "protocol" => "usenet"
        }
      ])
    end)

    assert {:ok, [result]} = Prowlarr.search_audiobook_query("B000FC0SIM", [])

    assert result.protocol == :usenet
    assert result.query_origins == [:free_text]
  end

  test "an explicit category list overrides the audiobook default" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["categories"] == "3000,3030"

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_audiobook_query("query", categories: [3000, 3030])
  end

  test "a non-200 response is an error, not an empty result" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:prowlarr_status, 500}} = Prowlarr.search_audiobook("Author", "Title", [])
  end

  test "audiobook_category/0 is the Audio/Audiobook category, distinct from the e-book one" do
    assert Prowlarr.audiobook_category() == 3030
    assert Prowlarr.audiobook_category() != Prowlarr.ebook_category()
  end
end
