defmodule Cinder.Catalog.TMDB.HTTPTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.TMDB.HTTP

  test "search/1 normalizes TMDB results, tolerating missing year/poster" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/movie"
      assert conn.params["query"] == "inception"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 27_205,
            "title" => "Inception",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg"
          },
          %{"id" => 1, "title" => "Obscure", "release_date" => "", "poster_path" => nil}
        ]
      })
    end)

    assert {:ok, results} = HTTP.search("inception")

    assert results == [
             %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"},
             %{tmdb_id: 1, title: "Obscure", year: nil, poster_path: nil}
           ]
  end

  test "search/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"status_message" => "no"})
    end)

    assert {:error, _} = HTTP.search("inception")
  end

  test "get_movie/1 normalizes a single (unwrapped) movie body" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205"

      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16",
        "poster_path" => "/p.jpg"
      })
    end)

    assert {:ok, %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}} =
             HTTP.get_movie(27_205)
  end
end
