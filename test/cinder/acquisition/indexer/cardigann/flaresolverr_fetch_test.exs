defmodule Cinder.Acquisition.Indexer.Cardigann.FlareSolverrFetchTest do
  # The FlareSolverr step of a Cardigann request (#1682) through
  # `Cinder.Acquisition.Indexer.Cardigann.Fetch.send_session/3`, the request step every search,
  # Test, login and captcha load takes, with the site behind `Cinder.CardigannStub` and
  # FlareSolverr behind `Cinder.FlareSolverrStub`. The request map is built here as the
  # adapter builds it.
  use ExUnit.Case, async: true

  import Cinder.CardigannFixtures, only: [route: 1]
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann.{Fetch, FlareSolverr, Jar}

  @fs "http://flaresolverr.lan:8191"
  @password "s3cret-Pa55"
  @ua "Mozilla/5.0 (X11; Linux x86_64) FlareSolverrTest/1.0"
  @title "<html><title>Just a moment...</title></html>"

  defp request(flaresolverr, extra \\ %{}) do
    Map.merge(
      %{
        context: %{deadline_at: System.monotonic_time(:millisecond) + 90_000},
        follow_redirects?: false,
        secrets: [@password],
        secret_referenced?: false,
        link_secret_referenced?: false,
        credential_hosts: MapSet.new(["site.test", "www.site.test", "admin.lan.test"]),
        now: ~U[2026-11-27 12:00:00Z],
        flaresolverr: flaresolverr
      },
      extra
    )
  end

  defp on(extra \\ %{}) do
    test_pid = self()

    Map.merge(
      %{
        mode: {:url, @fs},
        base_url: "https://site.test/",
        store: &send(test_pid, {:stored, &1})
      },
      extra
    )
  end

  defp challenge(status \\ 403, body \\ @title) do
    fn conn, _query ->
      conn
      |> Plug.Conn.put_resp_header("server", "cloudflare")
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  # The site answers each request with the next answer, the last one repeated.
  defp site(answers) do
    {:ok, queue} = Agent.start_link(fn -> answers end)

    route(%{
      "site.test" => fn conn, query ->
        case Agent.get_and_update(queue, fn
               [last] -> {last, [last]}
               [next | rest] -> {next, rest}
             end) do
          fun when is_function(fun, 2) -> fun.(conn, query)
          answer -> answer
        end
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
            "url" => "https://site.test/search?q=dune",
            "status" => 200,
            "cookies" => [
              %{"name" => "cf_clearance", "value" => "clear-1", "domain" => ".site.test"},
              %{"name" => "tracker", "value" => "x", "domain" => ".evil.test"}
            ],
            "userAgent" => @ua,
            "response" => "<html>the solved page</html>"
          },
          extra
        )
    }
  end

  # FlareSolverr answers each call with the next answer, the last one repeated; each call sends
  # the test `{:flaresolverr, payload, headers}`.
  defp flaresolverr(answers) do
    test_pid = self()
    {:ok, queue} = Agent.start_link(fn -> List.wrap(answers) end)

    Req.Test.stub(Cinder.FlareSolverrStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:flaresolverr, Jason.decode!(body), conn.request_path, conn.req_headers})

      answer =
        Agent.get_and_update(queue, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      case answer do
        {:transport, reason} ->
          Req.Test.transport_error(conn, reason)

        {status, body} when is_binary(body) ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(status, body)

        {status, %{} = json} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)

        fun when is_function(fun, 2) ->
          fun.(conn, body)
      end
    end)
  end

  defp calls do
    receive do
      {:flaresolverr, payload, path, _headers} -> [{path, payload} | calls()]
    after
      0 -> []
    end
  end

  # Each request the site received, as `{method, path, query, headers}`.
  defp site_requests do
    receive do
      {:cardigann_request, _host, path, query, headers} ->
        receive do
          {:cardigann_wire, _host, method, _path, _query_string, body} ->
            [{method, path, query, Map.new(headers), body} | site_requests()]
        end
    after
      0 -> []
    end
  end

  defp get(url, request), do: Fetch.send_session(%{url: url}, request, nil)

  describe "the toggle off or no URL" do
    test "a challenge is :cloudflare_challenge with no FlareSolverr call and no retry" do
      flaresolverr([{200, solution()}])

      for status <- [403, 503] do
        site([challenge(status)])

        assert {{:error, :cloudflare_challenge}, nil} =
                 get("https://site.test/search", request(%{mode: :off, base_url: "x"}))

        # One request: a challenged 503 gets no retry.
        assert [{"GET", "/search", _, _, _}] = site_requests()
      end

      # A request map with no FlareSolverr key at all (the canary task's) reads it as off.
      site([challenge()])
      assert {{:error, :cloudflare_challenge}, nil} = get("https://site.test/", request(nil))
      assert calls() == []
    end

    test "with the toggle on and no URL saved, a challenge is :flaresolverr_url_not_set" do
      site([challenge()])

      assert {{:error, :flaresolverr_url_not_set}, nil} =
               get("https://site.test/", request(%{mode: :no_url, base_url: "x"}))

      assert calls() == []
    end

    test "a page that is no challenge passes as today, and a plain 503 still gets its retry" do
      site([{503, "down"}, "<html>ok</html>"])

      assert {{:ok, %{body: "<html>ok</html>"}}, nil} =
               get("https://site.test/", request(%{mode: :off, base_url: "x"}))

      assert length(site_requests()) == 2
    end
  end

  describe "the solve and the replay" do
    test "the replay carries the clearance cookie and FlareSolverr's user agent" do
      site([challenge(), "<html>results</html>"])
      flaresolverr([{200, solution()}])

      assert {{:ok, %{body: "<html>results</html>"}}, nil} =
               get("https://site.test/search?q=dune", request(on()))

      assert [{"/v1", payload}] = calls()

      assert payload == %{
               "cmd" => "request.get",
               "url" => "https://site.test/search?q=dune",
               "maxTimeout" => 55_000
             }

      assert [{"GET", _, _, first, _}, {"GET", "/search", %{"q" => "dune"}, replay, _}] =
               site_requests()

      refute first["cookie"]
      refute first["user-agent"] == @ua
      assert replay["cookie"] == "cf_clearance=clear-1"
      assert replay["user-agent"] == @ua

      # The other domain's cookie is neither sent nor stored.
      assert_received {:stored,
                       %{user_agent: @ua, cookies: [{"site.test", "cf_clearance", "clear-1"}]}}
    end

    test "a replay answered with a second challenge is :cloudflare_challenge after one solve" do
      site([challenge()])
      flaresolverr([{200, solution()}])

      assert {{:error, :cloudflare_challenge}, nil} = get("https://site.test/", request(on()))
      assert length(calls()) == 1
      assert length(site_requests()) == 2
    end

    test "a stored clearance goes on every request to the definition's hosts, with no solve" do
      stored = %{user_agent: @ua, cookies: [{"site.test", "cf_clearance", "kept"}]}
      route(%{"www.site.test" => fn _conn, _query -> "<html>ok</html>" end})

      assert {{:ok, _page}, nil} =
               get("https://www.site.test/", request(on(%{read: fn -> stored end})))

      assert [{"GET", "/", _, headers, _}] = site_requests()
      # `www.site.test` domain-matches the cookie of `site.test`.
      assert headers["cookie"] == "cf_clearance=kept"
      assert headers["user-agent"] == @ua
      assert calls() == []
    end

    test "a stored clearance the site challenges anyway gets one solve and the new clearance" do
      stored = %{user_agent: "old agent", cookies: [{"site.test", "cf_clearance", "stale"}]}
      site([challenge(), "<html>ok</html>"])
      flaresolverr([{200, solution()}])

      assert {{:ok, _page}, nil} =
               get("https://site.test/", request(on(%{read: fn -> stored end})))

      assert [{"GET", _, _, first, _}, {"GET", _, _, replay, _}] = site_requests()
      assert first["cookie"] == "cf_clearance=stale"
      assert replay["cookie"] == "cf_clearance=clear-1"
      assert replay["user-agent"] == @ua
      assert length(calls()) == 1
    end

    test "with the toggle off, a stored clearance is not sent" do
      stored = %{user_agent: @ua, cookies: [{"site.test", "cf_clearance", "kept"}]}
      site(["<html>ok</html>"])

      assert {{:ok, _page}, nil} =
               get(
                 "https://site.test/",
                 request(%{mode: :off, base_url: "x", read: fn -> stored end})
               )

      assert [{"GET", "/", _, headers, _}] = site_requests()
      refute headers["cookie"]
    end

    test "a login's own cookie wins over a clearance cookie of the same name" do
      stored = %{
        user_agent: @ua,
        cookies: [{"site.test", "sid", "anon"}, {"site.test", "cf", "c"}]
      }

      site(["<html>ok</html>"])
      jar = Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=logged-in")

      assert {{:ok, _page}, _jar} =
               Fetch.send_session(
                 %{url: "https://site.test/"},
                 request(on(%{read: fn -> stored end})),
                 jar
               )

      assert [{"GET", "/", _, headers, _}] = site_requests()
      assert headers["cookie"] == "sid=logged-in; cf=c"
    end

    test "a clearance goes to no host outside the definition's" do
      stored = %{user_agent: @ua, cookies: [{"site.test", "cf_clearance", "kept"}]}
      route(%{"cdn.other.test" => fn _conn, _query -> "<html>ok</html>" end})

      assert {{:ok, _page}, nil} =
               get("https://cdn.other.test/", request(on(%{read: fn -> stored end})))

      assert [{"GET", "/", _, headers, _}] = site_requests()
      refute headers["cookie"]
      refute headers["user-agent"] == @ua
    end
  end

  describe "the call's failures" do
    test "each failure of the call is :flaresolverr_failed, and nothing is stored or replayed" do
      for answer <- [
            {404, "not found"},
            {200, "not json"},
            {500, %{"status" => "error", "message" => "Error solving the challenge."}},
            {200, solution(%{"cookies" => []})},
            {200, solution(%{"userAgent" => "  "})},
            {200, solution(%{"userAgent" => "agent\r\nx-injected: 1"})},
            {200, %{"status" => "ok"}},
            {:transport, :timeout},
            {:transport, :econnrefused},
            {200, Map.put(solution(), "pad", String.duplicate("a", FlareSolverr.max_bytes()))}
          ] do
        site([challenge(), "<html>ok</html>"])
        flaresolverr([answer])

        assert get("https://site.test/", request(on())) == {{:error, :flaresolverr_failed}, nil},
               inspect(answer, limit: 3, printable_limit: 40)

        assert length(site_requests()) == 1
        assert length(calls()) == 1
        refute_received {:stored, _clearance}
      end
    end

    test "an HTTP status other than 200 or 500 fails, even with a solution in its body" do
      site([challenge(), "<html>ok</html>"])
      flaresolverr([{404, solution()}])
      assert {{:error, :flaresolverr_failed}, nil} = get("https://site.test/", request(on()))
    end

    test "HTTP 500 with status ok is read, as FlareSolverr answers some solves" do
      site([challenge(), "<html>ok</html>"])
      flaresolverr([{500, solution()}])
      assert {{:ok, _page}, nil} = get("https://site.test/", request(on()))
    end

    test "a solution.url on another host is :flaresolverr_off_host" do
      for url <- ["https://evil.test/", "https://site.test.evil.test/", "not a url", nil] do
        site([challenge(), "<html>ok</html>"])
        flaresolverr([{200, solution(%{"url" => url})}])

        assert {{:error, :flaresolverr_off_host}, nil} = get("https://site.test/", request(on()))
        assert length(site_requests()) == 1
        refute_received {:stored, _clearance}
      end
    end

    test "a challenged URL off the definition's hosts is never handed over" do
      route(%{"cdn.other.test" => challenge()})

      # FlareSolverr was not asked, so the kind is the challenge's, not :flaresolverr_off_host.
      assert {{:error, :cloudflare_challenge}, nil} =
               get("https://cdn.other.test/", request(on()))

      assert calls() == []
    end

    test "a base URL that resolves to a forbidden address is never handed over" do
      site([challenge()])

      # A login's request solves on the base URL, here on the LAN.
      assert {{:error, :forbidden_address}, nil} =
               get(
                 "https://site.test/login",
                 request(on(%{base_url: "https://admin.lan.test/"}), %{login?: true})
               )

      assert calls() == []
    end

    test "the error and the log hold no trace of the URL or the body handed over" do
      body = "q=dune&token=t0ken-Echo"
      echo = fn conn, sent -> Plug.Conn.send_resp(conn, 500, sent) end

      for answer <- [echo, {:transport, :closed}] do
        site([challenge()])
        flaresolverr([answer])

        log =
          capture_log([level: :debug], fn ->
            assert {{:error, :flaresolverr_failed} = error, nil} =
                     Fetch.send_session(
                       %{url: "https://site.test/search?k=Echo-Key", method: :post, body: body},
                       request(on()),
                       nil
                     )

            refute inspect(error) =~ "Echo"
          end)

        assert [{"/v1", %{"postData" => ^body}}] = calls()
        site_requests()
        refute log =~ "Echo"
        refute log =~ "t0ken"
        refute log =~ "flaresolverr.lan"
      end
    end
  end

  describe "the secret rule" do
    test "a login POST carrying a password solves on the base URL, then replays the POST" do
      body = "username=me&password=#{@password}"
      site([challenge(), "<html>ok</html>"])
      flaresolverr([{200, solution()}])
      jar = Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "session=s1")

      assert {{:ok, _page}, _jar} =
               Fetch.send_session(
                 %{
                   url: "https://site.test/login",
                   method: :post,
                   body: body,
                   secret_body?: true,
                   retry: false,
                   site_headers: [{"x-site", "h"}]
                 },
                 request(on(), %{login?: true}),
                 jar
               )

      assert [{"/v1", payload}] = calls()

      assert payload == %{
               "cmd" => "request.get",
               "url" => "https://site.test/",
               "maxTimeout" => 55_000
             }

      refute inspect(payload) =~ @password
      refute inspect(payload) =~ "session"

      assert [{"POST", "/login", _, _, ^body}, {"POST", "/login", _, replay, ^body}] =
               site_requests()

      assert replay["cookie"] == "session=s1; cf_clearance=clear-1"
    end

    test "a body marked secret is handed as a GET of the base URL, the request no login's" do
      target = %{uri: URI.parse("https://site.test/s")}
      out = %{method: :post, body: "q=dune", secret_body?: true}

      assert FlareSolverr.handed(target, out, request(on()), on()) ==
               {:get, "https://site.test/"}

      # The positive control: the same body unmarked goes as request.post.
      assert FlareSolverr.handed(target, %{out | secret_body?: false}, request(on()), on()) ==
               {:post, "https://site.test/s", "q=dune"}
    end

    test "FlareSolverr's request carries no cookie and no header of the site's" do
      site([challenge(), "<html>ok</html>"])
      test_pid = self()

      Req.Test.stub(Cinder.FlareSolverrStub, fn conn ->
        send(test_pid, {:fs_headers, Map.new(conn.req_headers)})
        Req.Test.json(conn, solution())
      end)

      jar = Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "session=s1")

      Fetch.send_session(
        %{url: "https://site.test/", site_headers: [{"x-site", "h"}]},
        request(on()),
        jar
      )

      assert_received {:fs_headers, headers}
      refute headers["cookie"]
      refute headers["x-site"]
      refute inspect(headers) =~ "s1"
    end

    test "a POST with no secret goes as request.post with its body (positive control)" do
      body = "q=dune&cat=2"
      site([challenge(), "<html>ok</html>"])
      flaresolverr([{200, solution()}])

      Fetch.send_session(
        %{url: "https://site.test/s", method: :post, body: body},
        request(on()),
        nil
      )

      assert [{"/v1", payload}] = calls()

      assert payload == %{
               "cmd" => "request.post",
               "url" => "https://site.test/s",
               "postData" => body,
               "maxTimeout" => 55_000
             }
    end

    test "a multipart POST, a URL or body holding a secret, or a secret template solve on the base URL" do
      cases = [
        {%{
           url: "https://site.test/s",
           method: :post,
           body: "--b\r\nContent-Disposition: form-data; name=\"q\"\r\n\r\ndune\r\n--b--\r\n",
           content_type: "multipart/form-data; boundary=b"
         }, %{}},
        {%{url: "https://site.test/s?key=#{@password}"}, %{}},
        {%{
           url: "https://site.test/s",
           method: :post,
           body: "k=#{URI.encode_www_form(@password)}"
         }, %{}},
        {%{url: "https://site.test/s"}, %{secret_referenced?: true}}
      ]

      for {outgoing, extra} <- cases do
        site([challenge(), "<html>ok</html>"])
        flaresolverr([{200, solution()}])
        assert {{:ok, _page}, nil} = Fetch.send_session(outgoing, request(on(), extra), nil)

        assert [{"/v1", %{"cmd" => "request.get", "url" => "https://site.test/"} = payload}] =
                 calls()

        refute inspect(payload) =~ @password
        site_requests()
      end
    end
  end

  describe "deadlines" do
    test "maxTimeout is what is left of the budget at the solve, less 5 s" do
      for {left_ms, max_timeout} <- [{20_000, 15_000}, {90_000, 55_000}] do
        site([challenge(), "<html>ok</html>"])
        flaresolverr([{200, solution()}])

        request =
          request(on(), %{context: %{deadline_at: System.monotonic_time(:millisecond) + left_ms}})

        assert {{:ok, _page}, nil} = get("https://site.test/", request)
        assert [{"/v1", %{"maxTimeout" => ^max_timeout}}] = calls()
        site_requests()
      end
    end

    test "the replay runs under the budget's end, not the later seam deadline" do
      flaresolverr([{200, solution()}])
      started_ms = System.monotonic_time(:millisecond)
      request = request(on(), %{context: %{deadline_at: started_ms + 90_000}})
      target = %{uri: URI.parse("https://site.test/")}

      response =
        Req.Response.new(status: 403, body: @title)
        |> Req.Response.put_header("server", "cloudflare")

      assert {:replay, replay} = FlareSolverr.step(response, target, %{}, request, started_ms)
      assert replay.context.deadline_at == started_ms + 60_000
      assert replay.flaresolverr.solved? == true
    end

    test "with 5 s or less left of the budget, no solve is sent: the request reads :deadline" do
      site([challenge()])
      flaresolverr([{200, solution()}])

      request =
        request(on(), %{context: %{deadline_at: System.monotonic_time(:millisecond) + 4_000}})

      assert {{:error, :deadline}, nil} = get("https://site.test/", request)
      assert calls() == []
    end
  end
end
