defmodule Cinder.Library.MigrationSource.ReadarrTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.Library.MigrationSource.Readarr

  @fixture_path "test/support/fixtures/books/bookshelf-api-v1.json"
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("responses")

  @secret "test-key-must-never-leak"

  setup do
    original = Application.get_env(:cinder, Readarr)
    on_exit(fn -> Application.put_env(:cinder, Readarr, original) end)
    :ok
  end

  defp configure(local, api_key \\ "test-key") do
    Application.put_env(:cinder, Readarr,
      base_url: "http://bookshelf:8787",
      api_key: api_key,
      remote_path_prefix: "/library",
      local_path_prefix: local,
      req_options: [plug: {Req.Test, Cinder.ReadarrStub}, retry: false]
    )
  end

  defp local_dir do
    dir = Path.join(System.tmp_dir!(), "cinder-readarr-test")
    File.mkdir_p!(dir)
    dir
  end

  defp stub_snapshot_endpoints(api_key \\ "test-key") do
    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [api_key]

      case conn.request_path do
        "/api/v1/author" ->
          Req.Test.json(conn, @fixture["author"])

        "/api/v1/book" ->
          Req.Test.json(conn, @fixture["book"])

        "/api/v1/edition" ->
          Req.Test.json(conn, @fixture["edition"])

        "/api/v1/bookfile" ->
          Req.Test.json(conn, @fixture["bookfile"])

        "/api/v1/qualityprofile" ->
          Req.Test.json(conn, @fixture["qualityprofile"])

        "/api/v1/rootfolder" ->
          Req.Test.json(conn, @fixture["rootfolder"])

        "/api/v1/config/naming" ->
          Req.Test.json(conn, @fixture["config/naming"])
      end
    end)
  end

  test "snapshot/0 normalizes the committed B0 fixture into authors, works, editions, files, profiles, and roots" do
    local = local_dir()
    configure(local)
    stub_snapshot_endpoints()

    assert {:ok, snapshot} = Readarr.snapshot()

    assert snapshot.movies == []
    assert snapshot.series == []
    assert snapshot.episodes == []

    assert snapshot.authors == [
             %{
               provider_id: 1,
               name: "Fixture Author 1",
               foreign_id: "fixture-author-001",
               monitored: true,
               monitor_new_items: "all"
             },
             %{
               provider_id: 2,
               name: "Fixture Author 2",
               foreign_id: "fixture-author-002",
               monitored: true,
               monitor_new_items: "none"
             }
           ]

    assert snapshot.works == [
             %{
               provider_id: 1,
               author_id: 1,
               title: "Fixture Work 1",
               foreign_id: "fixture-work-001",
               monitored: true
             },
             %{
               provider_id: 2,
               author_id: 1,
               title: "Fixture Work 2",
               foreign_id: "fixture-work-002",
               monitored: true
             },
             %{
               provider_id: 3,
               author_id: 2,
               title: "Fixture Work 3",
               foreign_id: "fixture-work-003",
               monitored: true
             }
           ]

    assert snapshot.editions == [
             %{
               provider_id: 1,
               work_id: 1,
               isbn13: "9780000000019",
               asin: "FXT0000001",
               monitored: false
             },
             %{
               provider_id: 2,
               work_id: 1,
               isbn13: "9780000000026",
               asin: "FXT0000002",
               monitored: false
             },
             %{
               provider_id: 3,
               work_id: 2,
               isbn13: "9780000000033",
               asin: "FXT0000003",
               monitored: false
             },
             %{
               provider_id: 4,
               work_id: 3,
               isbn13: "9780000000040",
               asin: "FXT0000004",
               monitored: false
             }
           ]

    assert snapshot.files == [
             %{
               provider_id: 1,
               kind: :book,
               path: Path.join(local, "ebooks/Fixture Author 1/Fixture Work 1.epub"),
               size: 1024,
               work_id: 1,
               format: "epub"
             },
             %{
               provider_id: 2,
               kind: :book,
               path: Path.join(local, "ebooks/Fixture Author 1/Fixture Work 1.azw3"),
               size: 2048,
               work_id: 1,
               format: "azw3"
             },
             %{
               provider_id: 3,
               kind: :book,
               path: Path.join(local, "ebooks/Fixture Author 1/Fixture Work 2.mobi"),
               size: 4096,
               work_id: 2,
               format: "mobi"
             },
             %{
               provider_id: 4,
               kind: :book,
               path: Path.join(local, "audiobooks/Fixture Author 2/Fixture Work 3.m4b"),
               size: 8192,
               work_id: 3,
               format: "m4b"
             }
           ]

    assert snapshot.profiles == [
             %{provider_id: 1, name: "eBook"},
             %{provider_id: 2, name: "Spoken"}
           ]

    standard_format = "{Book Title}/{Author Name} - {Book Title}{ (PartNumber)}"

    assert snapshot.roots == [
             %{
               provider_id: 1,
               path: "/library/ebooks",
               rename_books: false,
               standard_book_format: standard_format
             },
             %{
               provider_id: 2,
               path: "/library/audiobooks",
               rename_books: false,
               standard_book_format: standard_format
             }
           ]
  end

  test "health/0 validates the observed system/status shape and succeeds" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      assert conn.request_path == "/api/v1/system/status"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      Req.Test.json(conn, @fixture["system/status"])
    end)

    assert :ok = Readarr.health()
  end

  test "health/0 fails loudly (not a raise) when version/branch has an unexpected shape" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      Req.Test.json(conn, %{"appName" => "Readarr", "branch" => "develop", "version" => 5})
    end)

    assert {:error, _reason} = Readarr.health()
  end

  test "health/0 fails loudly when branch is missing entirely" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      Req.Test.json(conn, %{"appName" => "Readarr", "version" => "0.4.20.129"})
    end)

    assert {:error, _reason} = Readarr.health()
  end

  test "snapshot/0 surfaces a non-200 status as a clean error, not a raise" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/author" -> Plug.Conn.send_resp(conn, 500, "boom")
        _other -> Req.Test.json(conn, [])
      end
    end)

    assert {:error, {:readarr_status, 500}} = Readarr.snapshot()
  end

  test "health/0 surfaces a non-200 status as a clean error" do
    configure(local_dir())
    Req.Test.stub(Cinder.ReadarrStub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert {:error, {:readarr_status, 503}} = Readarr.health()
  end

  test "snapshot/0 surfaces a transport failure (timeout) as a clean error, not a raise" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/author" -> Req.Test.transport_error(conn, :timeout)
        _other -> Req.Test.json(conn, [])
      end
    end)

    assert {:error, _reason} = Readarr.snapshot()
  end

  test "snapshot/0 rejects a malformed author row instead of raising" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/author" -> Req.Test.json(conn, [%{"id" => 1, "authorName" => nil}])
        _other -> Req.Test.json(conn, [])
      end
    end)

    assert {:error, :unexpected_response} = Readarr.snapshot()
  end

  test "snapshot/0 rejects a truncated bookfile row (missing size) instead of raising" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/author" ->
          Req.Test.json(conn, @fixture["author"])

        "/api/v1/book" ->
          Req.Test.json(conn, @fixture["book"])

        "/api/v1/edition" ->
          Req.Test.json(conn, @fixture["edition"])

        "/api/v1/bookfile" ->
          Req.Test.json(conn, [%{"id" => 1, "bookId" => 1, "path" => "/x.epub"}])

        "/api/v1/qualityprofile" ->
          Req.Test.json(conn, [])

        "/api/v1/rootfolder" ->
          Req.Test.json(conn, [])

        "/api/v1/config/naming" ->
          Req.Test.json(conn, %{})
      end
    end)

    assert {:error, :unexpected_response} = Readarr.snapshot()
  end

  test "snapshot/0 scopes the bookfile and edition collections the way the live API demands" do
    configure(local_dir())
    test_pid = self()

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      scopes = Enum.to_list(URI.query_decoder(conn.query_string))

      case {conn.request_path, scopes} do
        {"/api/v1/author", _} ->
          Req.Test.json(conn, @fixture["author"])

        {"/api/v1/book", _} ->
          Req.Test.json(conn, @fixture["book"])

        # 0.4.20.129's own failure modes for an unscoped collection GET: bookfile is a hard 500,
        # edition a silently empty list. Both would sink the whole migration.
        {"/api/v1/bookfile", []} ->
          Plug.Conn.send_resp(conn, 500, "authorId, bookId, bookFileIds or unmapped")

        {"/api/v1/edition", []} ->
          Req.Test.json(conn, [])

        {"/api/v1/bookfile", scopes} ->
          ids = for {"authorId", raw} <- scopes, do: String.to_integer(raw)
          send(test_pid, {:bookfile_scope, ids})
          Req.Test.json(conn, Enum.filter(@fixture["bookfile"], &(&1["authorId"] in ids)))

        {"/api/v1/edition", scopes} ->
          ids = for {"bookId", raw} <- scopes, do: String.to_integer(raw)
          send(test_pid, {:edition_scope, ids})
          Req.Test.json(conn, Enum.filter(@fixture["edition"], &(&1["bookId"] in ids)))

        {"/api/v1/qualityprofile", _} ->
          Req.Test.json(conn, @fixture["qualityprofile"])

        {"/api/v1/rootfolder", _} ->
          Req.Test.json(conn, @fixture["rootfolder"])

        {"/api/v1/config/naming", _} ->
          Req.Test.json(conn, @fixture["config/naming"])
      end
    end)

    assert {:ok, snapshot} = Readarr.snapshot()

    # Every file and edition still arrives, though no unscoped GET ever succeeds.
    assert Enum.map(snapshot.files, & &1.provider_id) == [1, 2, 3, 4]
    assert Enum.map(snapshot.editions, & &1.provider_id) == [1, 2, 3, 4]

    # One request per author, because the live build reads only the first `authorId` ...
    assert_received {:bookfile_scope, [1]}
    assert_received {:bookfile_scope, [2]}
    # ... and every work id in a single repeated-`bookId` request, which it does honour.
    assert_received {:edition_scope, [1, 2, 3]}
  end

  test "snapshot/0 surfaces a failure on one scoped request instead of a partial snapshot" do
    configure(local_dir())

    Req.Test.stub(Cinder.ReadarrStub, fn conn ->
      case {conn.request_path, conn.query_string} do
        {"/api/v1/author", _} -> Req.Test.json(conn, @fixture["author"])
        {"/api/v1/book", _} -> Req.Test.json(conn, @fixture["book"])
        {"/api/v1/edition", _} -> Req.Test.json(conn, @fixture["edition"])
        {"/api/v1/bookfile", "authorId=2"} -> Plug.Conn.send_resp(conn, 503, "down")
        {"/api/v1/bookfile", _} -> Req.Test.json(conn, @fixture["bookfile"])
        {_path, _query} -> Req.Test.json(conn, [])
      end
    end)

    assert {:error, {:readarr_status, 503}} = Readarr.snapshot()
  end

  test "the configured API key never appears in a snapshot error or health error" do
    configure(local_dir(), @secret)

    Req.Test.stub(Cinder.ReadarrStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    log =
      capture_log(fn ->
        {:error, snapshot_error} = Readarr.snapshot()
        {:error, health_error} = Readarr.health()

        refute inspect(snapshot_error) =~ @secret
        refute inspect(health_error) =~ @secret
      end)

    refute log =~ @secret
  end

  test "not_configured when base_url or api_key is blank" do
    Application.put_env(:cinder, Readarr, base_url: "", api_key: "")
    assert Readarr.snapshot() == {:error, :not_configured}
    assert Readarr.health() == {:error, :not_configured}
  end
end
