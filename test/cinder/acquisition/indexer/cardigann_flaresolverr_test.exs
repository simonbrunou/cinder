defmodule Cinder.Acquisition.Indexer.CardigannFlareSolverrTest do
  # FlareSolverr for a Cardigann indexer (#1682) through the real
  # `Cinder.Acquisition.IndexerSource.Native`: a search, a Test and a grab of a Torrent9-shaped
  # definition (`Cinder.CardigannFixtures`) whose site answers a Cloudflare challenge until a
  # request carries the clearance, behind the `Cinder.CardigannStub` and
  # `Cinder.FlareSolverrStub` plugs.
  #
  # Not async: Native's clock and the FlareSolverr URL setting are global.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerClearances, IndexerStatus}
  alias Cinder.ConfigCase
  alias Cinder.Indexers.FlareSolverrUrl

  @now ~U[2026-11-27 12:00:00Z]
  @fs "http://flaresolverr.lan:8191"
  @ua "Mozilla/5.0 (X11; Linux x86_64) FlareSolverrTest"
  @hash String.duplicate("a", 40)
  @magnet "magnet:?xt=urn:btih:#{@hash}&dn=Movie"
  @challenge """
  <!DOCTYPE html><html><head><title>Just a moment...</title></head><body></body></html>
  """

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp t9!(flaresolverr?, edit \\ & &1) do
    definition = torrent9_like(edit)

    [indexer] =
      setup!([{"t9.yml", definition}], [
        {"t9.yml", torrent9_base(), %{}, %{flaresolverr: flaresolverr?}}
      ])

    indexer
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp search_answer({:ok, rows, report}), do: {rows, outcomes(report)}
  defp search_answer({:error, {:no_indexer_answered, report}}), do: {[], outcomes(report)}

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  defp cleared?(conn) do
    cookies = conn |> Plug.Conn.get_req_header("cookie") |> Enum.join("; ")

    Plug.Conn.get_req_header(conn, "user-agent") == [@ua] and
      String.contains?(cookies, "cf_clearance=clear-1")
  end

  defp challenge(conn) do
    conn
    |> Plug.Conn.put_resp_header("server", "cloudflare")
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(403, @challenge)
  end

  # The site: each page `pages` names, by path, once the request carries the clearance; the
  # challenge before.
  defp site(pages) do
    route(%{
      "t9.test" => fn conn, _query ->
        if cleared?(conn),
          do: Map.get(pages, conn.request_path) || Map.fetch!(pages, :search),
          else: challenge(conn)
      end
    })
  end

  defp solution(extra \\ %{}) do
    %{
      "status" => "ok",
      "message" => "Challenge solved!",
      "solution" =>
        Map.merge(
          %{
            "url" => "https://t9.test/",
            "status" => 200,
            "cookies" => [
              %{"name" => "cf_clearance", "value" => "clear-1", "domain" => ".t9.test"}
            ],
            "userAgent" => @ua,
            "response" => "<html></html>"
          },
          extra
        )
    }
  end

  defp flaresolverr(answer) do
    test_pid = self()

    Req.Test.stub(Cinder.FlareSolverrStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:flaresolverr, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(answer)
    end)
  end

  defp calls do
    receive do
      {:flaresolverr, payload} -> [payload | calls()]
    after
      0 -> []
    end
  end

  defp rows,
    do: [%{title: "Dune Part Two 2024", href: "/details/1", size: "1,4 Go", icon: "film"}]

  describe "a search" do
    test "with the toggle on and a URL saved, solves once and the next search sends no call" do
      :ok = FlareSolverrUrl.put(@fs)
      indexer = t9!(true)
      site(%{search: torrent9_page(rows())})
      flaresolverr(solution())

      assert {:ok, [row], report} = Native.search_movie_query("dune", [])
      assert row.title == "Dune Part Two 2024"
      assert outcomes(report) == %{indexer.id => :asked}
      assert [%{"cmd" => "request.get", "url" => "https://t9.test/" <> _}] = calls()

      # The challenged request, then its replay.
      assert length(requests()) == 2
      refute IndexerClearances.read(indexer, @now) == nil

      assert {:ok, [_row], _report} = Native.search_movie_query("dune", [])
      assert calls() == []
      assert length(requests()) == 1
    end

    test "with the toggle off, a challenge records :cloudflare_challenge and calls nothing" do
      :ok = FlareSolverrUrl.put(@fs)
      indexer = t9!(false)
      site(%{search: torrent9_page(rows())})
      flaresolverr(solution())

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :cloudflare_challenge}}
      assert calls() == []
      assert status(indexer).last_failure == :cloudflare_challenge
    end

    test "with the toggle on and no URL saved, a challenge records :flaresolverr_url_not_set" do
      indexer = t9!(true)
      site(%{search: torrent9_page(rows())})
      flaresolverr(solution())

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :flaresolverr_url_not_set}}
      assert calls() == []
      assert status(indexer).last_failure == :flaresolverr_url_not_set
    end

    for {name, answer, kind} <- [
          {"an error answer", %{"status" => "error", "message" => "timeout"},
           :flaresolverr_failed},
          {"a solution on another host",
           %{
             "status" => "ok",
             "solution" => %{
               "url" => "https://elsewhere.test/",
               "cookies" => [%{"name" => "cf_clearance", "value" => "c", "domain" => ".t9.test"}],
               "userAgent" => "Mozilla/5.0"
             }
           }, :flaresolverr_off_host}
        ] do
      @answer answer
      @kind kind

      test "#{name} records #{inspect(kind)} after one call" do
        :ok = FlareSolverrUrl.put(@fs)
        indexer = t9!(true)
        site(%{search: torrent9_page(rows())})
        flaresolverr(@answer)

        assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
        assert outcomes == %{indexer.id => {:failed, @kind}}
        assert length(calls()) == 1
        assert status(indexer).last_failure == @kind
      end
    end
  end

  describe "a Test" do
    test "solves the challenge and passes" do
      :ok = FlareSolverrUrl.put(@fs)
      indexer = t9!(true)
      site(%{search: torrent9_page(rows())})
      flaresolverr(solution())

      assert {:ok, _result} = Native.test_indexer(indexer.id)
      assert length(calls()) == 1
    end
  end

  describe "a grab" do
    defp grab(indexer) do
      Native.fetch_download("https://t9.test/torrent/1", nil,
        max_bytes: 1024 * 1024,
        error_tag: :torrent_fetch_status,
        allow_magnet: true,
        indexer_source: "native",
        indexer_id: indexer.id,
        credentials_version: indexer.credentials_version
      )
    end

    test "a challenged details page is solved and its magnet comes back" do
      :ok = FlareSolverrUrl.put(@fs)
      indexer = t9!(true)
      site(%{"/torrent/1" => torrent9_details(link: @magnet), search: "<html></html>"})
      flaresolverr(solution())

      assert grab(indexer) == {:magnet, @magnet}
      assert [%{"cmd" => "request.get", "url" => "https://t9.test/torrent/1"}] = calls()
    end

    test "each fetch of a grab gets its own solve: the details page, then the torrent link" do
      :ok = FlareSolverrUrl.put(@fs)

      indexer =
        t9!(true, fn definition ->
          definition
          |> put_in(["download", "selectors"], [%{"selector" => "a.dl", "attribute" => "href"}])
          |> Map.put("testlinktorrent", "true")
        end)

      torrent = Cinder.TorrentFixture.minimal()

      route(%{
        "t9.test" => fn conn, _query ->
          cookies = conn |> Plug.Conn.get_req_header("cookie") |> Enum.join("; ")

          case conn.request_path do
            "/torrent/1" ->
              if cookies =~ "cf_clearance=clear-1",
                do: torrent9_details(link: "/dl/x.torrent"),
                else: challenge(conn)

            "/dl/x.torrent" ->
              if cookies =~ "cf_clearance=clear-2", do: {200, torrent}, else: challenge(conn)
          end
        end
      })

      test_pid = self()
      {:ok, count} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Cinder.FlareSolverrStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:flaresolverr, Jason.decode!(body)})
        n = Agent.get_and_update(count, &{&1 + 1, &1 + 1})
        cookie = %{"name" => "cf_clearance", "value" => "clear-#{n}", "domain" => ".t9.test"}
        Req.Test.json(conn, put_in(solution(), ["solution", "cookies"], [cookie]))
      end)

      assert grab(indexer) == {:ok, torrent}

      assert [%{"url" => "https://t9.test/torrent/1"}, %{"url" => "https://t9.test/dl/x.torrent"}] =
               calls()
    end

    test "an address refused before the call keeps the grab's bare :forbidden_address or :dns" do
      :ok = FlareSolverrUrl.put(@fs)
      indexer = t9!(true)
      site(%{"/torrent/1" => torrent9_details(link: @magnet), search: "<html></html>"})
      flaresolverr(solution())

      # The grab's own send resolves t9.test to a public address; the check before the call
      # resolves it again and gets the answer under test.
      for {answer, error} <- [{{:ok, [{10, 0, 0, 5}]}, :forbidden_address}, {:error, :dns}] do
        {:ok, lookups} = Agent.start_link(fn -> 0 end)

        resolver = fn _host ->
          if Agent.get_and_update(lookups, &{&1, &1 + 1}) == 0,
            do: {:ok, [{93, 184, 216, 34}]},
            else: answer
        end

        assert Native.fetch_download("https://t9.test/torrent/1", nil,
                 max_bytes: 1024 * 1024,
                 error_tag: :torrent_fetch_status,
                 allow_magnet: true,
                 indexer_source: "native",
                 indexer_id: indexer.id,
                 credentials_version: indexer.credentials_version,
                 resolver: resolver
               ) == {:error, error}
      end

      assert calls() == []
    end

    test "with the toggle off, a challenged details page is a :cloudflare_challenge grab error" do
      indexer = t9!(false)
      site(%{"/torrent/1" => torrent9_details(link: @magnet), search: "<html></html>"})
      flaresolverr(solution())

      assert grab(indexer) == {:error, {:cardigann_grab, :cloudflare_challenge}}
      assert calls() == []
    end
  end
end
