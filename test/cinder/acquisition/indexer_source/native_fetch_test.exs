defmodule Cinder.Acquisition.IndexerSource.NativeFetchTest do
  # A grab's link fetch through the real `IndexerSource.Native.fetch_download/3` and the real
  # Newznab and Torznab adapters (#1659): which origin it trusts, what it hands the client, and
  # what it records in the indexer's backoff state. The link answers from the
  # `Cinder.NativeGrabStub` plug passed in the client's fetch options, as a download client passes
  # its own `fetch_plug`; a search goes to `Cinder.NewznabStub` (`Cinder.NewznabFixtures`). Not
  # async: Native's config, the lease and the adapter map are global.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Cinder.NewznabFixtures

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerStatus, Lease}
  alias Cinder.ConfigCase
  alias Cinder.Download
  alias Cinder.Download.Client.{Fetch, QBittorrent, Sabnzbd}
  alias Cinder.Indexers
  alias Cinder.NzbFixture
  alias Cinder.Repo

  @lan "http://192.168.1.10:5076"
  @public_address {93, 184, 216, 34}

  defmodule SearchOnlyAdapter do
    @moduledoc false
    # An adapter that searches but implements no grab fetch.
    @behaviour Cinder.Acquisition.Indexer

    @impl true
    def search(_indexer, _query, _context), do: {[], :asked}

    @impl true
    def test(_indexer, _context, _record), do: {:not_run, {:skipped, :deadline}}
  end

  setup do
    ConfigCase.put_env(Native, [])
    :ok
  end

  # The fetch options a download client passes, plus the provenance `Cinder.Download` adds.
  defp opts(indexer, extra \\ []) do
    test_pid = self()

    Keyword.merge(
      [
        max_bytes: 1024 * 1024,
        error_tag: :nzb_fetch_status,
        plug: {Req.Test, Cinder.NativeGrabStub},
        resolver: fn host ->
          send(test_pid, {:dns, host})
          {:ok, [@public_address]}
        end,
        indexer_source: "native",
        indexer_id: indexer.id,
        credentials_version: indexer.credentials_version
      ],
      extra
    )
  end

  # Stubs the link's host with `fun`, which takes the conn and answers through `respond/2`; every
  # request tells the test process its path.
  defp link_answers(fun) do
    test_pid = self()

    Req.Test.stub(Cinder.NativeGrabStub, fn conn ->
      send(test_pid, {:grab_request, conn.request_path})
      respond(conn, fun.(conn))
    end)
  end

  defp redirect(location), do: {302, [{"location", location}], ""}

  defp lan_indexer!(type \\ :newznab), do: indexer!(type, "unused.example", %{base_url: @lan})

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  # A failure backoff from an earlier answer, so a grab that records anything shows in the row.
  defp failing!(indexer) do
    :written = IndexerStatus.record(indexer, {:http_status, 500}, DateTime.utc_now())
    status(indexer)
  end

  defp fetch(indexer, link, extra \\ []),
    do: Native.fetch_download(link, nil, opts(indexer, extra))

  describe "the trusted origin" do
    test "a link on the indexer's LAN base URL is fetched unpinned" do
      indexer = lan_indexer!()
      nzb = NzbFixture.minimal()
      link_answers(fn _conn -> nzb end)

      assert {:ok, ^nzb} = fetch(indexer, "#{@lan}/getnzb/1.nzb?apikey=#{key()}")
      assert_received {:grab_request, "/getnzb/1.nzb"}
      refute_received {:dns, _host}
    end

    test "the same link on another origin is refused at a LAN address and fetched at a public one" do
      indexer = indexer!(:newznab, "unused.example", %{base_url: "http://192.168.1.11:5076"})
      nzb = NzbFixture.minimal()
      link_answers(fn _conn -> nzb end)

      assert {:error, :forbidden_address} = fetch(indexer, "#{@lan}/getnzb/1.nzb")
      refute_received {:grab_request, _path}

      assert {:ok, ^nzb} = fetch(indexer, "https://files.example/getnzb/1.nzb")
      assert_received {:dns, "files.example"}
      assert_received {:grab_request, "/getnzb/1.nzb"}
    end

    test "the row's origin wins over the stored one: a link on the stored origin is untrusted" do
      indexer = indexer!(:newznab, "unused.example", %{base_url: "http://192.168.1.11:5076"})
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :forbidden_address} =
               Native.fetch_download("#{@lan}/getnzb/1.nzb", @lan, opts(indexer))

      refute_received {:grab_request, _path}
    end

    test "a same-origin redirect stays trusted; a cross-origin redirect to a LAN address is refused" do
      indexer = lan_indexer!()
      nzb = NzbFixture.minimal()

      link_answers(fn conn ->
        case conn.request_path do
          "/same" -> redirect("#{@lan}/file.nzb")
          "/cross" -> redirect("http://192.168.1.20/file.nzb")
          "/file.nzb" -> nzb
        end
      end)

      assert {:ok, ^nzb} = fetch(indexer, "#{@lan}/same")
      assert_received {:grab_request, "/file.nzb"}

      assert {:error, :forbidden_address} = fetch(indexer, "#{@lan}/cross")
      assert_received {:grab_request, "/cross"}
      refute_received {:grab_request, "/file.nzb"}
    end

    test "a disabled configured indexer still fetches" do
      indexer = lan_indexer!()
      {:ok, _row} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)
      nzb = NzbFixture.minimal()
      link_answers(fn _conn -> nzb end)

      assert {:ok, ^nzb} = fetch(indexer, "#{@lan}/getnzb/1.nzb")
    end
  end

  describe "a magnet redirect" do
    test "a Torznab link that redirects to a magnet answers the magnet under allow_magnet" do
      indexer = lan_indexer!(:torznab)
      magnet = "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}&dn=Movie"
      link_answers(fn _conn -> redirect(magnet) end)

      assert {:magnet, ^magnet} = fetch(indexer, "#{@lan}/dl/1", allow_magnet: true)
    end

    test "a Newznab link that redirects to a magnet is refused without allow_magnet" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> redirect("magnet:?xt=urn:btih:#{String.duplicate("a", 40)}") end)

      assert {:error, :unsupported_download_url} = fetch(indexer, "#{@lan}/getnzb/1")
    end
  end

  describe "a magnet redirect through the real clients" do
    # Each client fetches through its own `fetch_plug`, which also answers its API.
    defp provenance(indexer),
      do: [indexer_source: "native", indexer_id: indexer.id, credentials_version: 1]

    test "a Torznab link that redirects to a magnet gives qBittorrent the sanitized magnet" do
      indexer = lan_indexer!(:torznab)
      test_pid = self()
      hash = String.duplicate("ab", 20)
      bad = URI.encode_www_form("http://127.0.0.1/announce")
      good = URI.encode_www_form("udp://tracker.example:1337/announce")

      Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
        case {conn.host, conn.request_path} do
          {"192.168.1.10", "/dl/1"} ->
            respond(conn, redirect("magnet:?xt=urn:btih:#{hash}&dn=Movie&tr=#{bad}&tr=#{good}"))

          {_api, "/api/v2/auth/login"} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
            |> Req.Test.text("Ok.")

          {_api, "/api/v2/torrents/add"} ->
            send(test_pid, {:posted, conn.params["urls"]})
            Req.Test.text(conn, "Ok.")
        end
      end)

      release = %{download_url: "#{@lan}/dl/1", download_url_origin: nil}
      fetch = Download.fetch_function(Native, provenance(indexer))

      assert {:ok, ^hash} = QBittorrent.add(release, fetch: fetch)
      assert_received {:posted, urls}

      # `Torrent.sanitize_magnet/2` rebuilds the link, dropping the tracker on a forbidden address.
      assert urls ==
               "magnet:?xt=urn%3Abtih%3A#{hash}&dn=Movie&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce"
    end

    test "a Newznab link that redirects to a magnet is refused under SABnzbd" do
      indexer = lan_indexer!()
      test_pid = self()

      Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
        case conn.host do
          "192.168.1.10" ->
            respond(conn, redirect("magnet:?xt=urn:btih:#{String.duplicate("ab", 20)}"))

          _api ->
            send(test_pid, {:sabnzbd_api, conn.params["mode"]})
            Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-1"]})
        end
      end)

      release = %{title: "Movie", download_url: "#{@lan}/getnzb/1", download_url_origin: nil}
      fetch = Download.fetch_function(Native, provenance(indexer))

      assert {:error, :unsupported_download_url} =
               Sabnzbd.add(release, operation_key: "k", fetch: fetch)

      refute_received {:sabnzbd_api, "addfile"}
    end
  end

  describe "which configured indexer" do
    test "a deleted configured indexer gives :indexer_changed with no request" do
      indexer = lan_indexer!()
      :ok = Indexers.delete(nil, indexer.id)
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :indexer_changed} = fetch(indexer, "#{@lan}/getnzb/1")
      refute_received {:grab_request, _path}
    end

    test "fetch options whose configured indexer id is not an integer give :indexer_changed with no request" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :indexer_changed} =
               fetch(indexer, "#{@lan}/getnzb/1", indexer_id: Integer.to_string(indexer.id))

      refute_received {:grab_request, _path}
    end

    test "fetch options with no credentials version give :indexer_changed with no request" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :indexer_changed} =
               fetch(indexer, "#{@lan}/getnzb/1", credentials_version: nil)

      refute_received {:grab_request, _path}
    end

    test "fetch options with no configured indexer id give :indexer_changed with no request" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :indexer_changed} = fetch(indexer, "#{@lan}/getnzb/1", indexer_id: nil)
      refute_received {:grab_request, _path}
    end

    test "secrets that no longer decrypt give :indexer_changed with no request" do
      indexer = lan_indexer!()
      :ok = undecryptable!(indexer)
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :indexer_changed} = fetch(indexer, "#{@lan}/getnzb/1")
      refute_received {:grab_request, _path}
    end

    # The key rotated after `GrabFailure.check/1` passed: the link still holds the old key, so
    # the row the fetch would record under is not the one the grab was searched with.
    test "credentials changed after the grab's check give :indexer_changed with no request" do
      indexer = lan_indexer!()
      {:ok, row} = Indexers.fetch_with_secrets(indexer.id)

      {:ok, rotated} =
        Indexers.update(nil, row.id, row.lock_version, %{}, %{"api_key" => "rotated-key"})

      assert rotated.credentials_version > indexer.credentials_version
      link_answers(fn _conn -> {401, "Unauthorized"} end)

      assert {:error, :indexer_changed} = fetch(indexer, "#{@lan}/getnzb/1")
      refute_received {:grab_request, _path}
      assert Repo.get(IndexerStatus, indexer.id) == nil
    end

    test "a type whose adapter has no fetch_download/3 reads not supported with no request" do
      indexer = lan_indexer!()
      ConfigCase.put_env(:indexer_adapters, %{newznab: SearchOnlyAdapter})
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :not_supported} = fetch(indexer, "#{@lan}/getnzb/1")
      refute_received {:grab_request, _path}
    end

    # The Cardigann adapter has no `fetch_download/3`: its grab is #1672's.
    test "a Cardigann configured indexer reads not supported with no request" do
      cardigann =
        Repo.insert!(%Cinder.Indexers.ConfiguredIndexer{
          name: "Cardigann",
          type: :cardigann,
          definition: "nyaasi",
          base_url: @lan
        })

      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:error, :not_supported} = fetch(cardigann, "#{@lan}/download/1.torrent")
      refute_received {:grab_request, _path}
    end
  end

  describe "the spacing lease" do
    test "a grab sent while another call holds the indexer's lease slot does not wait for it" do
      indexer = lan_indexer!()
      nzb = NzbFixture.minimal()
      link_answers(fn _conn -> nzb end)
      test_pid = self()

      holder =
        start_supervised!(
          {Task,
           fn ->
             deadline = [deadline_at: System.monotonic_time(:millisecond) + 30_000]

             ran =
               Lease.run(indexer.id, deadline, fn ->
                 send(test_pid, :holding)

                 receive do
                   :release -> :ok
                 end
               end)

             send(test_pid, {:held, ran})
           end}
        )

      assert_receive :holding, 5_000

      started = System.monotonic_time(:millisecond)
      assert {:ok, ^nzb} = fetch(indexer, "#{@lan}/getnzb/1")
      assert System.monotonic_time(:millisecond) - started < 5_000

      send(holder, :release)
      assert_receive {:held, {:ran, :ok}}, 5_000
    end
  end

  describe "what the grab records" do
    test "Newznab error 101 from the base URL origin rejects the credentials; the next search sends nothing" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> error(101, "Account suspended") end)

      assert {:error, :indexer_auth_failed} = fetch(indexer, "#{@lan}/getnzb/1")
      assert %{credentials_rejected: true, credentials_rejected_by: nil} = status(indexer)

      route(%{})
      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")
      refute_received {:newznab_request, _host, _query}
    end

    test "a redirect on the base URL origin to a login page rejects the credentials unfollowed" do
      indexer = lan_indexer!()

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> redirect("#{@lan}/login")
        end
      end)

      assert {:error, :indexer_auth_failed} = fetch(indexer, "#{@lan}/getnzb/1")
      refute_received {:grab_request, "/login"}
      assert %{credentials_rejected: true} = status(indexer)
    end

    test "a login redirect after five redirects on the base URL origin records nothing" do
      indexer = lan_indexer!()
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/hop/5" -> redirect("#{@lan}/login")
          "/hop/" <> n -> redirect("#{@lan}/hop/#{String.to_integer(n) + 1}")
        end
      end)

      assert {:error, :too_many_redirects} = fetch(indexer, "#{@lan}/hop/0")
      assert_received {:grab_request, "/hop/5"}
      assert status(indexer) == before
    end

    test "HTTP 401 from the base URL origin rejects the credentials" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> {401, "Unauthorized"} end)

      assert {:error, :indexer_auth_failed} = fetch(indexer, "#{@lan}/getnzb/1")
      assert %{credentials_rejected: true} = status(indexer)
    end

    test "the same answers after a cross-origin redirect leave the state unchanged" do
      indexer = lan_indexer!()
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> redirect("https://files.example/#{conn.query_string}")
          "/" -> error(101, "Account suspended")
        end
      end)

      assert {:error, :bad_download_file} = fetch(indexer, "#{@lan}/getnzb/1")
      assert status(indexer) == before
    end

    test "HTTP 429 with Retry-After: 600 starts a limit backoff ending 10 min later" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> {429, [{"retry-after", "600"}], ""} end)
      now = DateTime.utc_now(:second)

      assert {:error, {:indexer_limit, until}} = fetch(indexer, "#{@lan}/getnzb/1")
      assert %{backoff: :limit, backoff_until: ^until} = status(indexer)
      assert DateTime.diff(until, now) in 600..601
    end

    test "Prowlarr's 429 \"Indexer is disabled till\" starts a failure backoff ending at its Retry-After; a passing Test ends it" do
      indexer = indexer!(:newznab, "prowlarr.example", %{base_url: "https://prowlarr.example"})
      body = error(429, "Indexer is disabled till 2026-11-26 12:00:00 due to recent failures")
      link_answers(fn _conn -> {429, [{"retry-after", "900"}], body} end)
      now = DateTime.utc_now(:second)

      assert {:error, :indexer_disabled} = fetch(indexer, "https://prowlarr.example/1/download")

      assert %{backoff: :failure, backoff_until: until, last_failure: :http_status} =
               status(indexer)

      assert DateTime.diff(until, now) in 900..901

      route(%{"prowlarr.example" => fn _conn, _query -> :default end})
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert %{backoff: :none, backoff_until: nil} = status(indexer)
    end

    test "HTTP 503 records one failure step" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> {503, "down"} end)
      now = DateTime.utc_now(:second)

      assert {:error, {:nzb_fetch_status, 503}} = fetch(indexer, "#{@lan}/getnzb/1")

      assert %{
               backoff: :failure,
               level: 1,
               failures_in_row: 1,
               last_failure: :http_status,
               last_failure_code: 503,
               backoff_until: until
             } = status(indexer)

      assert DateTime.diff(until, now) in 60..61
    end

    test "HTTP 500 and 599, the ends of the 5xx range, each record one failure step" do
      for status <- [500, 599] do
        indexer = indexer!(:newznab, "s#{status}.example", %{base_url: @lan})
        link_answers(fn _conn -> {status, "down"} end)

        assert {:error, {:nzb_fetch_status, ^status}} = fetch(indexer, "#{@lan}/getnzb/1")

        assert %{
                 backoff: :failure,
                 level: 1,
                 last_failure: :http_status,
                 last_failure_code: ^status
               } =
                 status(indexer)
      end
    end

    test "Newznab error 900 records one failure step" do
      indexer = lan_indexer!()
      link_answers(fn _conn -> error(900, "Unknown error") end)

      assert {:error, {:indexer_error, 900}} = fetch(indexer, "#{@lan}/getnzb/1")

      assert %{backoff: :failure, level: 1, last_failure: :indexer_error, last_failure_code: 900} =
               status(indexer)
    end

    test "an HTML page from the base URL origin records a challenge failure step" do
      indexer = lan_indexer!()

      link_answers(fn _conn ->
        "<!doctype html><html><body>Checking your browser</body></html>"
      end)

      assert {:error, :challenge_page} = fetch(indexer, "#{@lan}/getnzb/1")
      assert %{backoff: :failure, level: 1, last_failure: :challenge} = status(indexer)
    end

    test "a redirect from https to http on the link's origin records a failure step" do
      indexer = indexer!(:newznab, "secure.example")
      link_answers(fn _conn -> redirect("http://secure.example/file.nzb") end)

      assert {:error, :https_downgrade} = fetch(indexer, "https://secure.example/getnzb/1")
      assert %{backoff: :failure, level: 1, last_failure: :bad_response} = status(indexer)
    end

    test "a redirect from https to http off the link's origin records nothing" do
      indexer = indexer!(:newznab, "secure.example")
      before = failing!(indexer)
      link_answers(fn _conn -> redirect("http://cdn.example/file.nzb") end)

      assert {:error, :https_downgrade} = fetch(indexer, "https://files.example/getnzb/1")
      assert status(indexer) == before
    end

    test "a redirect from https to http sent by a host the link redirected to records nothing" do
      indexer = indexer!(:newznab, "secure.example")
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> redirect("https://cdn.example/file.nzb")
          "/file.nzb" -> redirect("http://cdn.example/file.nzb")
        end
      end)

      assert {:error, :https_downgrade} = fetch(indexer, "https://secure.example/getnzb/1")
      assert_received {:grab_request, "/file.nzb"}
      assert status(indexer) == before
    end

    test "an answer from the base URL origin after a hop off it records nothing" do
      indexer = indexer!(:newznab, "secure.example")
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> redirect("https://files.example/back")
          "/back" -> redirect("https://secure.example/api")
          "/api" -> error(101, "Account suspended")
        end
      end)

      assert {:error, :bad_download_file} = fetch(indexer, "https://secure.example/getnzb/1")
      assert_received {:grab_request, "/api"}
      assert status(indexer) == before
    end

    test "a challenge page, a 401 and a 503 after a cross-origin redirect record nothing" do
      indexer = lan_indexer!()
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/" <> path -> redirect("https://files.example/#{path}")
          "/html" -> "<!doctype html><html><body>Checking your browser</body></html>"
          "/401" -> {401, "Unauthorized"}
          "/503" -> {503, "down"}
        end
      end)

      assert {:error, :challenge_page} = fetch(indexer, "#{@lan}/getnzb/html")
      assert {:error, {:nzb_fetch_status, 401}} = fetch(indexer, "#{@lan}/getnzb/401")
      assert {:error, {:nzb_fetch_status, 503}} = fetch(indexer, "#{@lan}/getnzb/503")
      assert status(indexer) == before
    end

    test "a body that is no file, a 404 and a transport error record nothing" do
      indexer = lan_indexer!()
      before = failing!(indexer)

      link_answers(fn conn ->
        case conn.request_path do
          "/text" -> "not an nzb"
          "/gone" -> {404, "missing"}
          "/down" -> {:transport, :econnrefused}
        end
      end)

      assert {:error, :bad_download_file} = fetch(indexer, "#{@lan}/text")
      assert {:error, {:nzb_fetch_status, 404}} = fetch(indexer, "#{@lan}/gone")
      assert {:error, %Req.TransportError{}} = fetch(indexer, "#{@lan}/down")
      assert status(indexer) == before
    end

    test "a recognised NZB records nothing" do
      indexer = lan_indexer!()
      before = failing!(indexer)
      link_answers(fn _conn -> NzbFixture.minimal() end)

      assert {:ok, _nzb} = fetch(indexer, "#{@lan}/getnzb/1")
      assert status(indexer) == before
    end

    test "a fetch that started before an edit raised config_version records nothing" do
      indexer = lan_indexer!()

      link_answers(fn _conn ->
        {:ok, row} = Indexers.fetch_with_secrets(indexer.id)
        {:ok, _edited} = Indexers.update(nil, row.id, row.lock_version, %{api_path: "/api2"})
        {503, "down"}
      end)

      assert {:error, {:nzb_fetch_status, 503}} = fetch(indexer, "#{@lan}/getnzb/1")
      assert Repo.get(IndexerStatus, indexer.id) == nil
    end

    test "a fetch whose configured indexer was deleted meanwhile records nothing" do
      indexer = lan_indexer!()

      link_answers(fn _conn ->
        :ok = Indexers.delete(nil, indexer.id)
        {503, "down"}
      end)

      # Dropped before any write: no insert that the foreign key refuses, so no warning.
      log =
        capture_log(fn ->
          assert {:error, {:nzb_fetch_status, 503}} = fetch(indexer, "#{@lan}/getnzb/1")
        end)

      assert Repo.get(IndexerStatus, indexer.id) == nil
      refute log =~ "not recorded"
    end

    test "the key in the link never reaches the error or the log" do
      indexer = lan_indexer!()
      link = "#{@lan}/getnzb/1?apikey=#{key()}"

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> {429, [{"x-echo", conn.query_string}], "limit for #{conn.query_string}"}
          "/getnzb/2" -> {:transport, :econnrefused}
        end
      end)

      log =
        capture_log(fn ->
          for path <- ["1", "2"] do
            result = fetch(indexer, String.replace(link, "/1?", "/#{path}?"))
            refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ key()
            send(self(), {:result, result})
          end
        end)

      assert_received {:result, {:error, {:indexer_limit, _until}}}
      assert_received {:result, {:error, %Req.TransportError{reason: :econnrefused}}}
      refute log =~ key()
    end
  end

  describe "which host gave the answer (Fetch.attributed/3)" do
    test "the origin's own answer and its downgrade are the source's" do
      indexer = indexer!(:newznab, "secure.example")
      nzb = NzbFixture.minimal()

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> nzb
          "/getnzb/2" -> redirect("http://secure.example/file.nzb")
        end
      end)

      assert {{:ok, %{trusted: true}}, true} =
               Fetch.attributed(
                 "https://secure.example/getnzb/1",
                 "https://secure.example",
                 opts(indexer)
               )

      assert {{:error, :https_downgrade}, true} =
               Fetch.attributed(
                 "https://secure.example/getnzb/2",
                 "https://secure.example",
                 opts(indexer)
               )
    end

    test "a link refused before any request and a downgrade a CDN sent are not the source's" do
      indexer = indexer!(:newznab, "secure.example")

      link_answers(fn conn ->
        case conn.request_path do
          "/getnzb/1" -> redirect("https://cdn.example/file.nzb")
          "/file.nzb" -> redirect("http://cdn.example/file.nzb")
        end
      end)

      assert {{:error, :unsupported_download_url}, false} =
               Fetch.attributed(
                 "ftp://secure.example/getnzb/1",
                 "https://secure.example",
                 opts(indexer)
               )

      assert {{:error, :https_downgrade}, false} =
               Fetch.attributed(
                 "https://secure.example/getnzb/1",
                 "https://secure.example",
                 opts(indexer)
               )
    end
  end
end
