defmodule Cinder.Download.FetchSourceTest do
  # A download client fetches a grab's http(s) link through the indexer source its intent
  # recorded, and an intent whose source maps to no module makes no fetch (#1650).
  # Not async: the grab tests below use global mocks.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Acquisition.Release
  alias Cinder.Download
  alias Cinder.Download.{ClientMock, Intent}

  setup :set_mox_global
  setup :verify_on_exit!

  describe "fetch_source/1" do
    # The test env's configured source is `IndexerMock`, so a mapping that read the app env would
    # answer it instead of Prowlarr.
    setup do
      assert Application.fetch_env!(:cinder, :indexer_source) == IndexerMock
      :ok
    end

    test "an intent with no recorded source fetches through Prowlarr with its provenance" do
      intent = %Intent{release: %{"indexer_id" => 7, "credentials_version" => 2}}

      assert Download.fetch_source(intent) ==
               {:ok, Prowlarr,
                [indexer_source: "prowlarr", indexer_id: 7, credentials_version: 2]}
    end

    test "an intent that records prowlarr and no ids fetches through Prowlarr with nil ids" do
      intent = %Intent{release: %{"indexer_source" => "prowlarr"}}

      assert Download.fetch_source(intent) ==
               {:ok, Prowlarr,
                [indexer_source: "prowlarr", indexer_id: nil, credentials_version: nil]}
    end

    test "an intent that records any other source has no fetch source" do
      for source <- ["native", "torznab", ""] do
        intent = %Intent{release: %{"indexer_source" => source, "indexer_id" => 7}}

        assert {source, Download.fetch_source(intent)} ==
                 {source, {:error, :unknown_indexer_source}}
      end
    end
  end

  describe "a grab's client" do
    @link "https://indexer.example/dl/1.torrent"
    @origin "https://indexer.example"

    defp reserve(movie, source) do
      Download.reserve_intent(%{
        kind: :movie,
        target_id: movie.id,
        episode_ids: [],
        protocol: :torrent,
        release: %Release{
          title: "Movie.2010.1080p-GRP",
          download_url: @link,
          download_url_origin: @origin,
          protocol: :torrent,
          indexer_id: 7,
          indexer_source: source
        }
      })
    end

    test "gets a fetch: function that reaches the link through Fetch.bytes/3" do
      test_pid = self()
      movie = movie_fixture(%{status: :searching})
      # No recorded source: an intent reserved before #1645 is Prowlarr's.
      assert {:ok, intent} = reserve(movie, nil)
      refute Map.has_key?(intent.release, "indexer_source")

      Req.Test.stub(Cinder.FetchSourceStub, fn conn ->
        send(test_pid, {:fetched, conn.host, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "torrent bytes")
      end)

      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      stub(ClientMock, :add, fn release, opts ->
        answer =
          Keyword.fetch!(opts, :fetch).(release.download_url, release.download_url_origin,
            max_bytes: 64,
            error_tag: :torrent_fetch_status,
            plug: {Req.Test, Cinder.FetchSourceStub},
            resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
          )

        send(test_pid, {:added, answer, Keyword.delete(opts, :fetch)})
        {:ok, "remote-1"}
      end)

      assert :ok = Download.reconcile_pending_intents([:movie])

      key = intent.operation_key
      assert_received {:added, {:ok, "torrent bytes"}, [operation_key: ^key]}
      assert_received {:fetched, "indexer.example", "/dl/1.torrent"}
      assert Repo.reload!(movie).download_id == "remote-1"
    end

    test "is never called for an intent that records an unknown source, which retries" do
      test_pid = self()
      movie = movie_fixture(%{status: :searching})
      assert {:ok, intent} = reserve(movie, "native")
      assert intent.release["indexer_source"] == "native"

      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      stub(ClientMock, :add, fn _release, _opts ->
        send(test_pid, :added)
        {:ok, "remote-1"}
      end)

      assert {:error, :unknown_indexer_source} = Download.start(Repo.reload!(movie))
      refute_received :added

      assert %Intent{status: :reserved, attempt_count: 1, last_error: ":unknown_indexer_source"} =
               fresh = Repo.get(Intent, intent.id)

      assert DateTime.compare(fresh.next_attempt_at, DateTime.utc_now()) == :gt
    end
  end

  describe "fetch_function/2" do
    test "calls the source's fetch_download/3 with the client's options and the provenance" do
      test_pid = self()

      expect(IndexerMock, :fetch_download, fn url, origin, opts ->
        send(test_pid, {:fetch_download, url, origin, opts})
        {:magnet, "magnet:?xt=urn:btih:abc"}
      end)

      provenance = [indexer_source: "prowlarr", indexer_id: 7, credentials_version: nil]
      fetch = Download.fetch_function(IndexerMock, provenance)

      assert {:magnet, "magnet:?xt=urn:btih:abc"} =
               fetch.("https://indexer.example/1", "https://indexer.example",
                 max_bytes: 10,
                 error_tag: :torrent_fetch_status
               )

      assert_received {:fetch_download, "https://indexer.example/1", "https://indexer.example",
                       opts}

      assert Enum.sort(opts) ==
               Enum.sort(
                 max_bytes: 10,
                 error_tag: :torrent_fetch_status,
                 indexer_source: "prowlarr",
                 indexer_id: 7,
                 credentials_version: nil
               )
    end

    test "the provenance keys win over the client's keys of the same name" do
      test_pid = self()

      expect(IndexerMock, :fetch_download, fn _url, _origin, opts ->
        send(test_pid, {:opts, opts})
        {:error, :some_tag}
      end)

      provenance = [indexer_source: "prowlarr", indexer_id: nil, credentials_version: 2]
      fetch = Download.fetch_function(IndexerMock, provenance)

      assert {:error, :some_tag} =
               fetch.("https://indexer.example/1", nil,
                 max_bytes: 10,
                 indexer_source: "native",
                 indexer_id: 99,
                 credentials_version: 5
               )

      assert_received {:opts, opts}

      assert Enum.sort(opts) ==
               Enum.sort(
                 max_bytes: 10,
                 indexer_source: "prowlarr",
                 indexer_id: nil,
                 credentials_version: 2
               )
    end
  end
end
