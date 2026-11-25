defmodule Cinder.Indexers.Definitions.SourceTest do
  # Sets the `:indexer_definitions_source` key and the GitHub adapter's config, which every
  # process reads.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.ConfigCase
  alias Cinder.Indexers.Definitions.{OtherSourceMock, Set, Source, SourceMock}
  alias Cinder.Indexers.Definitions.Source.GitHub
  alias Cinder.Test.{DefinitionsZip, GitAdvertisement}

  setup :verify_on_exit!

  @commit "56b20b19c18fee53869fca2bca72ba59101da2f9"
  @stored "0123456789abcdef0123456789abcdef01234567"
  @versions "MIN_VERSION=11\nMAX_VERSION=12\n"

  defp advertisement(commit) do
    GitAdvertisement.advertisement([
      "#{commit} HEAD\0agent=git/github\n",
      "#{commit} refs/heads/master\n"
    ])
  end

  defp zip(commit),
    do: DefinitionsZip.codeload(commit, [{"VERSIONS", @versions}, {"definitions/v11/a.yml", "x"}])

  # Points the source at the GitHub adapter, whose requests reach `Cinder.DefinitionsSourceStub`:
  # master names `master`, and the zip is `zip(master)`. Each request is reported to the test.
  defp github_master(master) do
    ConfigCase.put_env(:indexer_definitions_source, GitHub)
    test_pid = self()

    Req.Test.stub(Cinder.DefinitionsSourceStub, fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})

      case conn.host do
        "github.com" -> Plug.Conn.send_resp(conn, 200, advertisement(master))
        "codeload.github.com" -> Plug.Conn.send_resp(conn, 200, zip(master))
      end
    end)
  end

  describe "fetch/1 through the GitHub adapter" do
    test "answers :unchanged when master still names the stored commit, with no codeload request" do
      github_master(@commit)

      assert :unchanged = Source.fetch(@commit)
      assert_received {:request, "github.com", "/Prowlarr/Indexers.git/info/refs"}
      refute_received {:request, "codeload.github.com", _path}
    end

    test "downloads and reads the zip when master names another commit, or none is stored" do
      github_master(@commit)

      for stored <- [@stored, nil] do
        assert {:ok, @commit, set} = Source.fetch(stored)

        assert %Set{commit: @commit, versions: %{min: 11, max: 12}, files: [%{name: "a.yml"}]} =
                 set

        assert_received {:request, "github.com", "/Prowlarr/Indexers.git/info/refs"}
        assert_received {:request, "codeload.github.com", "/Prowlarr/Indexers/zip/" <> @commit}
      end
    end

    test "answers the reader's error for the downloaded zip" do
      ConfigCase.put_env(:indexer_definitions_source, GitHub)

      Req.Test.stub(Cinder.DefinitionsSourceStub, fn
        %{host: "github.com"} = conn -> Plug.Conn.send_resp(conn, 200, advertisement(@commit))
        conn -> Plug.Conn.send_resp(conn, 200, zip(@stored))
      end)

      assert {:error, :archive_layout} = Source.fetch(nil)
    end

    test "answers the source's error for master or the download" do
      ConfigCase.put_env(:indexer_definitions_source, GitHub)

      Req.Test.stub(Cinder.DefinitionsSourceStub, &Plug.Conn.send_resp(&1, 503, ""))
      assert {:error, {:http_status, 503}} = Source.fetch(nil)

      Req.Test.stub(Cinder.DefinitionsSourceStub, fn
        %{host: "github.com"} = conn -> Plug.Conn.send_resp(conn, 200, advertisement(@commit))
        conn -> Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:error, {:http_status, 404}} = Source.fetch(nil)
    end

    test "a request past its deadline gives :timeout" do
      ConfigCase.put_env(:indexer_definitions_source, GitHub)
      ConfigCase.put_config(GitHub, deadline_ms: 200)

      # Holds the request until the deadline kills its task; the stub never answers.
      Req.Test.stub(Cinder.DefinitionsSourceStub, fn conn ->
        receive do
          :never -> conn
        end
      end)

      {elapsed_us, result} = :timer.tc(fn -> Source.fetch(nil) end)

      assert {:error, :timeout} = result
      # Under the 30 s deadline the seam replaces: a fetch that ignores the seam waits that out.
      assert elapsed_us < 15_000_000
    end
  end

  describe "the GitHub adapter's pinned request options" do
    test "configured req_options cannot change the method, the URL, redirects or retries" do
      ConfigCase.put_config(GitHub,
        req_options: [
          plug: {Req.Test, Cinder.DefinitionsSourceStub},
          method: :post,
          url: "https://example.com/elsewhere",
          params: [extra: "1"],
          redirect: true,
          retry: :transient,
          retry_delay: 0
        ]
      )

      test_pid = self()

      # info/refs answers a redirect, which a followed redirect would turn into a second request;
      # the zip answers a 503, which a retry would send again.
      Req.Test.stub(Cinder.DefinitionsSourceStub, fn conn ->
        send(test_pid, {:request, conn.method, conn.host, conn.request_path, conn.query_string})

        case conn.host do
          "github.com" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://github.com/elsewhere")
            |> Plug.Conn.send_resp(301, "")

          _codeload ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      assert {:error, {:http_status, 301}} = GitHub.master_commit()

      assert_received {:request, "GET", "github.com", "/Prowlarr/Indexers.git/info/refs",
                       "service=git-upload-pack"}

      refute_received {:request, _method, _host, _path, _query}

      assert {:error, {:http_status, 503}} = GitHub.download(@commit)
      assert_received {:request, "GET", "codeload.github.com", "/Prowlarr/Indexers/zip/" <> _, ""}
      refute_received {:request, _method, _host, _path, _query}
    end
  end

  describe "fetch/1 through a mock" do
    test "reads the source from :indexer_definitions_source" do
      ConfigCase.put_env(:indexer_definitions_source, OtherSourceMock)
      stub(SourceMock, :master_commit, fn -> {:error, :transport} end)
      expect(OtherSourceMock, :master_commit, fn -> {:ok, @commit} end)

      assert :unchanged = Source.fetch(@commit)
    end

    test "never downloads when master names the stored commit" do
      test_pid = self()
      expect(SourceMock, :master_commit, fn -> {:ok, @commit} end)
      stub(SourceMock, :download, fn commit -> send(test_pid, {:download, commit}) end)

      assert :unchanged = Source.fetch(@commit)
      refute_received {:download, _commit}

      expect(SourceMock, :master_commit, fn -> {:ok, @commit} end)
      expect(SourceMock, :download, fn @commit -> {:ok, zip(@commit)} end)

      assert {:ok, @commit, %{commit: @commit}} = Source.fetch(@stored)
    end
  end
end
