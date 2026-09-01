defmodule Cinder.Books.Metadata.HardcoverTest do
  use ExUnit.Case, async: false

  alias Cinder.Books.Metadata.Hardcover

  # The proxy's response shape is frozen in provider-v1.json; this is one case's work document,
  # trimmed to the fields the adapter reads.
  @work %{
    "foreign_id" => 736_076,
    "title" => "Beloved",
    "release_date" => "1987-09-16 07:00:00",
    "authors" => [%{"foreign_id" => 3534, "name" => "Toni Morrison"}],
    "series" => [%{"foreign_id" => 304_306, "title" => "Beloved Trilogy", "position" => nil}],
    "editions" => [
      %{
        "foreign_id" => 6149,
        "title" => "Beloved",
        "format" => "Paperback",
        "is_ebook" => false,
        "language" => "eng",
        "publisher" => "Vintage",
        "release_date" => "2004-06-08 07:00:00",
        "isbn13" => nil,
        "asin" => ""
      },
      %{
        "foreign_id" => 6150,
        "title" => "Beloved",
        "format" => "ebook",
        "is_ebook" => false,
        "language" => "eng",
        "publisher" => "Vintage",
        "release_date" => "2004-06-08 07:00:00",
        "isbn13" => "9781400033416",
        "asin" => "B000FC0SIM"
      },
      %{
        "foreign_id" => 6151,
        "title" => "Beloved",
        "format" => "Audible Audio",
        "is_ebook" => false,
        "language" => "eng"
      }
    ]
  }

  test "get_work/1 normalizes the proxy's work document" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      assert conn.request_path == "/work/736076"
      Req.Test.json(conn, @work)
    end)

    assert {:ok, work} = Hardcover.get_work("736076")
    assert work.provider == :hardcover
    assert work.foreign_id == "736076"
    assert work.first_published_on == ~D[1987-09-16]
    assert work.contributors == [%{foreign_id: "3534", name: "Toni Morrison", role: "author"}]
    assert work.series == [%{name: "Beloved Trilogy", position: nil}]

    # Print bindings are dropped; `is_ebook` is false even for the proxy's own "ebook" format, so
    # the format string decides and the flag is only a fallback.
    assert [ebook, audiobook] = work.editions
    assert ebook.foreign_id == "6150"
    assert ebook.media_kind == :ebook
    assert ebook.release_date == ~D[2004-06-08]
    assert ebook.isbn13 == "9781400033416"
    assert ebook.asin == "B000FC0SIM"
    assert audiobook.media_kind == :audiobook
    # An empty-string asin is absence, not an identifier.
    assert audiobook.asin == nil
  end

  test "bibliography/1 normalizes full work documents directly, one bounded request" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      assert conn.request_path == "/author/3534/works"
      Req.Test.json(conn, %{"works" => [@work, %{"title" => "Malformed, no foreign_id"}]})
    end)

    assert {:ok, [candidate]} = Hardcover.bibliography("3534")
    assert candidate.provider == :hardcover
    assert candidate.foreign_id == "736076"
    assert candidate.title == "Beloved"
    assert candidate.edition_count == 2
  end

  test "search/1 fetches each hit's work document, since search returns bare ids" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      case conn.request_path do
        "/search" ->
          assert conn.params["q"] == "Beloved Toni Morrison"
          Req.Test.json(conn, [%{"work_id" => 736_076, "book_id" => 6149, "author_id" => 3534}])

        "/work/736076" ->
          Req.Test.json(conn, @work)
      end
    end)

    assert {:ok, [candidate]} = Hardcover.search("Beloved Toni Morrison")
    assert candidate.foreign_id == "736076"
    assert candidate.title == "Beloved"
    assert candidate.first_published_year == 1987
    # The observed digital editions, which is what the resolver's tie-break wants.
    assert candidate.edition_count == 2
  end

  test "a hit that cannot be fetched drops out instead of failing the whole search" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      case conn.request_path do
        "/search" -> Req.Test.json(conn, [%{"work_id" => 1}, %{"work_id" => 736_076}])
        "/work/1" -> Plug.Conn.send_resp(conn, 500, "boom")
        "/work/736076" -> Req.Test.json(conn, @work)
      end
    end)

    assert {:ok, [%{foreign_id: "736076"}]} = Hardcover.search("Beloved Toni Morrison")
  end

  test "a search where all hits fail to fetch returns an error" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      case conn.request_path do
        "/search" -> Req.Test.json(conn, [%{"work_id" => 1}, %{"work_id" => 2}])
        "/work/1" -> Plug.Conn.send_resp(conn, 500, "boom")
        "/work/2" -> Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    assert {:error, :all_fetches_failed} = Hardcover.search("Beloved Toni Morrison")
  end

  test "a search with no hits returns {:ok, []}" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      case conn.request_path do
        "/search" -> Req.Test.json(conn, [])
      end
    end)

    assert {:ok, []} = Hardcover.search("Nonexistent Title")
  end

  test "an unconfigured proxy is not an outage: every call says so explicitly" do
    config = Application.get_env(:cinder, Hardcover)
    on_exit(fn -> Application.put_env(:cinder, Hardcover, config) end)
    Application.put_env(:cinder, Hardcover, Keyword.delete(config, :base_url))

    assert {:error, :not_configured} = Hardcover.search("anything")
    assert {:error, :not_configured} = Hardcover.get_work("736076")
  end

  test "a payload whose ids are not ids is refused or dropped, never coerced" do
    # `to_string/1` raises on a map. Everything here runs inside the refresher's `isolate/2`,
    # which only logs what it rescues, so a raise would recur on every 12h tick forever.
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      Req.Test.json(conn, %{@work | "foreign_id" => %{"nested" => true}})
    end)

    assert {:error, :unexpected_response} = Hardcover.get_work("736076")

    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      Req.Test.json(conn, %{
        @work
        | "authors" => [%{"foreign_id" => ["list"], "name" => "Toni Morrison"}],
          "editions" => [
            %{"foreign_id" => %{}, "title" => "Beloved", "format" => "ebook"} | @work["editions"]
          ]
      })
    end)

    assert {:ok, work} = Hardcover.get_work("736076")
    assert work.contributors == []
    assert work.contributors_incomplete
    assert Enum.map(work.editions, & &1.foreign_id) == ["6150", "6151"]
  end

  test "a partial contributor drop is flagged, not reported as a complete work" do
    # The list is non-empty, so testing it for emptiness would call this work complete and the
    # missing contributor would be invisible — `contributors_incomplete` is the only signal an
    # operator gets. A total drop is the easy case and both rules agree on it; this is the one
    # that separates them.
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      Req.Test.json(conn, %{
        @work
        | "authors" => [
            %{"foreign_id" => %{"bad" => true}, "name" => "Toni Morrison"},
            %{"foreign_id" => 99, "name" => "Second Author"}
          ]
      })
    end)

    assert {:ok, work} = Hardcover.get_work("736076")
    assert Enum.map(work.contributors, & &1.name) == ["Second Author"]
    assert work.contributors_incomplete
  end

  test "a numeric series position survives as written rather than being dropped" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      Req.Test.json(conn, %{
        @work
        | "series" => [%{"foreign_id" => 1, "title" => "Beloved Trilogy", "position" => 1.5}]
      })
    end)

    assert {:ok, %{series: [%{name: "Beloved Trilogy", position: "1.5"}]}} =
             Hardcover.get_work("736076")
  end

  test "a non-200 and a malformed body each fail without a partial work" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn -> Plug.Conn.send_resp(conn, 502, "bad") end)
    assert {:error, {:hardcover_status, 502}} = Hardcover.get_work("736076")

    Req.Test.stub(Cinder.HardcoverStub, fn conn -> Req.Test.json(conn, %{"title" => "no id"}) end)
    assert {:error, :unexpected_response} = Hardcover.get_work("736076")

    Req.Test.stub(Cinder.HardcoverStub, fn conn -> Req.Test.json(conn, ["not a work"]) end)
    assert {:error, :unexpected_response} = Hardcover.get_work("736076")
  end

  test "health/0 is :ok on a 200, surfaces a non-200 status, and reports :not_configured when unset" do
    Req.Test.stub(Cinder.HardcoverStub, fn conn ->
      assert conn.request_path == "/search"
      Req.Test.json(conn, [])
    end)

    assert :ok = Hardcover.health()

    Req.Test.stub(Cinder.HardcoverStub, fn conn -> Plug.Conn.send_resp(conn, 502, "bad") end)
    assert {:error, {:hardcover_status, 502}} = Hardcover.health()

    config = Application.get_env(:cinder, Hardcover)
    on_exit(fn -> Application.put_env(:cinder, Hardcover, config) end)
    Application.put_env(:cinder, Hardcover, Keyword.delete(config, :base_url))

    assert {:error, :not_configured} = Hardcover.health()
  end
end
