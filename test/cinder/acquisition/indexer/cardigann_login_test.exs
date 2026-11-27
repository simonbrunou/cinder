defmodule Cinder.Acquisition.Indexer.CardigannLoginTest do
  # The Cardigann logins (#1680) through the real `Cinder.Acquisition.IndexerSource.Native`, on
  # definitions written for Cinder (`Cinder.CardigannFixtures`), behind the
  # `Cinder.CardigannStub` plug. Every page runs through a real parser worker.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures
  import Ecto.Query

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.Indexer.Cardigann.{Jar, Session}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCookies, IndexerStatus}
  alias Cinder.ConfigCase

  @now ~U[2026-11-26 12:00:00Z]
  @password "pw-Secret-91"
  @secrets %{"username" => "frieren", "password" => @password}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  # --- the definitions ---

  defp login_like(login, edit) do
    nyaa_like(fn definition ->
      definition
      |> Map.put("type", "private")
      |> Map.update!("settings", fn settings ->
        [
          %{"name" => "username", "type" => "text", "label" => "Username"},
          %{"name" => "password", "type" => "password", "label" => "Password"}
          | settings
        ]
      end)
      |> Map.put("login", login)
      |> edit.()
    end)
  end

  defp post_login(extra \\ %{}) do
    Map.merge(
      %{
        "method" => "post",
        "path" => "login.php",
        "inputs" =>
          obj([
            {"username", "{{ .Config.username }}"},
            {"password", "{{ .Config.password }}"},
            {"keeplogged", "1"}
          ]),
        "error" => [%{"selector" => "div.error"}],
        "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
      },
      extra
    )
  end

  defp login!(login, edit \\ & &1, secrets \\ @secrets) do
    [indexer] =
      setup!([{"login.yml", login_like(login, edit)}], [{"login.yml", nyaa_base(), secrets}])

    indexer
  end

  # --- the stub's answers ---

  defp frieren do
    [
      %{
        title: "[Group] Frieren - 01 [1080p]",
        magnet: "magnet:?xt=urn:btih:" <> String.duplicate("1", 40),
        size: "1.4 GiB",
        date: "2026-11-25 10:30",
        cat: "1_2"
      }
    ]
  end

  # A search page of a session: the Nyaa page with a log-out link, the test selector's match.
  defp session_page,
    do:
      String.replace(nyaa_page(frieren()), "<body>", ~s|<body><a href="/logout.php">Log out</a>|)

  defp with_cookie(conn, cookie) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", cookie <> "; path=/; HttpOnly")
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<!doctype html><html><body><p>Welcome</p></body></html>")
  end

  defp cookie(conn), do: conn |> Plug.Conn.get_req_header("cookie") |> Enum.join("; ")

  # The site: `/login.php` sets the session cookie; a search page answers with it, and
  # redirects to the login page without it.
  defp site(login_answer \\ &with_cookie(&1, "sid=s3ss10n")) do
    route(%{
      "nyaa.test" => fn conn, _query ->
        case conn.request_path do
          "/login.php" ->
            login_answer.(conn)

          "/" ->
            if cookie(conn) =~ "sid=s3ss10n",
              do: session_page(),
              else: {:redirect, 302, "https://nyaa.test/login.php"}
        end
      end
    })
  end

  # Every request so far as `{method, path, cookie header}`, in order.
  defp sent do
    receive do
      {:cardigann_request, _host, path, _query, headers} ->
        cookie = for({"cookie", value} <- headers, do: value) |> Enum.join("; ")

        receive do
          {:cardigann_wire, _host, method, ^path, _query_string, body} ->
            [{method, path, cookie, body} | sent()]
        end
    after
      0 -> []
    end
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp stored(indexer) do
    case IndexerCookies.read(indexer, @now) do
      {:ok, %{jar: jar}} -> Jar.to_list(jar)
      :miss -> :miss
    end
  end

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  # A parser worker that exits at once, in place of the real one (`ParserWorker`'s moduledoc).
  defp crashing_worker!(tmp) do
    path = Path.join(tmp, "erl")
    File.write!(path, "#!/bin/sh\nexit 3\n")
    File.chmod!(path, 0o755)
    ConfigCase.put_env(:parser_worker_erl, path)
  end

  # A stored session of `indexer`, as an earlier login left it.
  defp stored!(indexer, cookie \\ "sid=0ld", at \\ @now) do
    uri = URI.parse(nyaa_base())
    jar = Jar.put_string(Jar.new(), uri, cookie)
    assert IndexerCookies.store_login(indexer, jar, at) == :written
  end

  defp counts(sent) do
    Enum.frequencies_by(sent, fn {_method, path, _cookie, _body} -> path end)
  end

  describe "a post login" do
    test "logs in, stores the cookie row, and the search sends the session cookie" do
      indexer = login!(post_login())
      site()

      assert {:ok, [row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
      assert row.title == "[Group] Frieren - 01 [1080p]"

      assert [
               {"POST", "/login.php", "", body},
               {"GET", "/", "sid=s3ss10n", _}
             ] = sent()

      assert body == "username=frieren&password=#{@password}&keeplogged=1"
      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]

      # The next search reads the stored row and sends no login.
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"GET", "/", "sid=s3ss10n", _}] = sent()
    end

    test "login.cookies go on the login request as fixed cookies" do
      login!(post_login(%{"cookies" => ["lang=en", "agreed=yes"]}))
      site()

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"POST", "/login.php", cookie, _body}, {"GET", "/", search_cookie, _}] = sent()
      assert cookie == "agreed=yes; lang=en"
      assert search_cookie =~ "sid=s3ss10n"
    end

    test "login.cookies go to every one of the definition's hosts, a login redirect's included" do
      login!(post_login(%{"cookies" => ["lang=en"]}))

      route(%{
        "nyaa.test" => fn conn, _query ->
          case conn.request_path do
            "/login.php" ->
              conn
              |> Plug.Conn.put_resp_header("set-cookie", "sid=s3ss10n; path=/")
              |> Plug.Conn.put_resp_header("location", "https://old-nyaa.test/welcome")
              |> Plug.Conn.send_resp(302, "")

            "/" ->
              session_page()
          end
        end,
        "old-nyaa.test" => fn _conn, _query -> "<html><body>Welcome</body></html>" end
      })

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:cardigann_request, "old-nyaa.test", "/welcome", _query, headers}
      assert {"cookie", "lang=en"} in headers
    end
  end

  describe "a get login" do
    test "sends the inputs as a query, stores the row, and the search sends the cookie" do
      indexer = login!(%{post_login() | "method" => "get"})
      site()

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      # The site answers the search only with the session cookie.
      assert [
               {"nyaa.test", "GET", "/login.php", query_string, ""},
               {"nyaa.test", "GET", "/", _, _}
             ] =
               wire()

      assert query_string == "username=frieren&password=#{@password}&keeplogged=1"
      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]
    end
  end

  describe "a cookie login" do
    defp cookie_login,
      do: %{
        "method" => "cookie",
        "inputs" => obj([{"cookie", "{{ .Config.cookie }}"}]),
        "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
      }

    defp with_cookie_setting(definition) do
      Map.update!(definition, "settings", fn settings ->
        settings ++
          [
            %{"name" => "cookie", "type" => "text", "label" => "Cookie"},
            %{"name" => "info_cookie", "type" => "info_cookie", "label" => "About the cookie"}
          ]
      end)
    end

    test "sends no login request: the saved cookie goes on the search, and the row is stored" do
      indexer =
        login!(cookie_login(), &with_cookie_setting/1, %{"cookie" => "sid=s3ss10n; uid=7"})

      site()

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
      assert [{"GET", "/", "sid=s3ss10n; uid=7", _}] = sent()

      # Fixed cookies, for every one of the definition's hosts.
      assert stored(indexer) == [["sid", "s3ss10n"], ["uid", "7"]]
    end

    test "the saved cookie goes to every one of the definition's hosts, a redirect's included" do
      follow = fn definition ->
        definition |> with_cookie_setting() |> Map.put("followredirect", "true")
      end

      indexer = login!(cookie_login(), follow, %{"cookie" => "sid=s3ss10n"})

      route(%{
        "nyaa.test" => fn _conn, _query -> {:redirect, 302, "https://old-nyaa.test/"} end,
        "old-nyaa.test" => fn conn, _query ->
          if cookie(conn) == "sid=s3ss10n",
            do: session_page(),
            else: "<html><body>Log in</body></html>"
        end
      })

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
      assert_received {:cardigann_request, "old-nyaa.test", "/", _query, headers}
      assert {"cookie", "sid=s3ss10n"} in headers
    end

    test "a login sign rejects the cookie at once, with no resend" do
      indexer = login!(cookie_login(), &with_cookie_setting/1, %{"cookie" => "sid=expired"})
      site()

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert [{"GET", "/", "sid=expired", _}] = sent()

      status = status(indexer)

      assert {status.credentials_rejected, status.credentials_rejected_by} ==
               {true, :login_cookie}
    end

    test "a login sign under a stored row rejects the cookie at once, with no new seed" do
      indexer = login!(cookie_login(), &with_cookie_setting/1, %{"cookie" => "sid=expired"})
      stored!(indexer, "sid=0ld")
      site()

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert [{"GET", "/", "sid=0ld", _}] = sent()
      assert status(indexer).credentials_rejected_by == :login_cookie
    end
  end

  describe "a form login" do
    defp landing do
      """
      <!doctype html><html><body>
      <form action="/takelogin.php" method="post">
        <input name="user_x" type="text" value="">
        <input type="password" name="pass_x">
        <input type="checkbox" name="remember" value="1" checked>
        <input type="checkbox" name="unchecked" value="1">
        <input type="radio" name="r" value="a"><input type="radio" name="r" value="b" checked>
        <input name="dis" value="d" disabled>
        <input value="no name">
        <input type="hidden" name="tok" value="t0k3n">
      </form>
      <form action="/search"><input name="q" value="x"></form>
      <span id="key">k3y</span>
      </body></html>
      """
    end

    # The site of a form login: `landing` at `/login.php`, the submit at `submit_path`.
    defp form_site(landing, submit_path, extra \\ %{}) do
      route(%{
        "nyaa.test" => fn conn, _query ->
          case Map.get(extra, conn.request_path) do
            nil ->
              case conn.request_path do
                "/login.php" -> landing
                ^submit_path -> with_cookie(conn, "sid=s3ss10n")
                "/" -> session_page()
              end

            answer ->
              answer
          end
        end
      })
    end

    test "the default form's inputs, checked boxes, selectors, selector inputs and the submit path" do
      indexer =
        login!(%{
          "method" => "form",
          "path" => "login.php",
          "submitpath" => "/do-login.php",
          "selectors" => true,
          "inputs" =>
            obj([
              {~s|input[type="text"]|, "{{ .Config.username }}"},
              {~s|input[type="password"]|, "{{ .Config.password }}"},
              {"b#n1", "1"},
              {"b#n2", "2"}
            ]),
          "selectorinputs" =>
            obj([{"csrf", %{"selector" => ~s|input[name="tok"]|, "attribute" => "value"}}]),
          "getselectorinputs" => obj([{"gsk", %{"selector" => "span#key"}}]),
          "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
        })

      # Two named elements outside the form, whose names the form lacks.
      named = ~s|<b id="n1" name="extra_a"></b><b id="n2" name="extra_b"></b><span id="key">|
      form_site(String.replace(landing(), ~s|<span id="key">|, named), "/do-login.php")

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert [
               {"nyaa.test", "GET", "/login.php", "", ""},
               {"nyaa.test", "POST", "/do-login.php", "gsk=k3y", body},
               {"nyaa.test", "GET", "/", _, _}
             ] = wire()

      assert body ==
               "user_x=frieren&pass_x=#{@password}&remember=1&r=b&tok=t0k3n&extra_a=1&extra_b=2&csrf=t0k3n"

      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]
    end

    test "a named form's action, multipart/form-data and the simpleCaptcha answer" do
      landing = """
      <!doctype html><html><body>
      <form id="other" action="/nope"><input name="x" value="1"></form>
      <form id="login" action="/takelogin.php" enctype="multipart/form-data">
        <input name="username"><input name="password" type="password">
      </form>
      <script src="/js/simpleCaptcha.js"></script>
      </body></html>
      """

      login!(%{
        "method" => "form",
        "path" => "login.php",
        "form" => "form#login",
        "inputs" =>
          obj([
            {"username", "{{ .Config.username }}"},
            {"password", "{{ .Config.password }}"}
          ]),
        "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
      })

      captcha = {200, "application/json", ~s|{"images":[{"hash":"h4sh"},{"hash":"other"}]}|}
      form_site(landing, "/takelogin.php", %{"/simpleCaptcha.php" => captcha})

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      assert [
               {"nyaa.test", "GET", "/login.php", "", ""},
               {"nyaa.test", "GET", "/simpleCaptcha.php", "numImages=1", ""},
               {"nyaa.test", "POST", "/takelogin.php", "", body},
               {"nyaa.test", "GET", "/", _, _}
             ] = wire()

      for {name, value} <- [
            {"username", "frieren"},
            {"password", @password},
            {"captchaSelection", "h4sh"},
            {"submitme", "X"}
          ] do
        assert body =~ ~s|name="#{name}"\r\n\r\n#{value}\r\n|
      end

      refute body =~ ~s|name="x"|
    end

    test "the submit carries the landing page as its Referer and a multipart content type" do
      login!(%{
        "method" => "form",
        "path" => "login.php",
        "inputs" => obj([{"user_x", "{{ .Config.username }}"}]),
        "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
      })

      landing =
        String.replace(
          landing(),
          ~s|<form action="/takelogin.php"|,
          ~s|<form enctype="multipart/form-data" action="/takelogin.php"|
        )

      form_site(landing, "/takelogin.php")

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:cardigann_request, "nyaa.test", "/takelogin.php", _query, headers}
      assert {"referer", "https://nyaa.test/login.php"} in headers
      assert [content_type] = for({"content-type", value} <- headers, do: value)
      assert content_type =~ ~r/\Amultipart\/form-data; boundary=\S+\z/
    end

    test "a postman-shaped login with no method logs in as a form login" do
      landing = """
      <!doctype html><html><body>
      <form action="index.php?view=Login" method="post">
        <input name="username"><input name="password" type="password">
        <input type="hidden" name="formtoken" value="ft1">
      </form>
      </body></html>
      """

      indexer =
        login!(%{
          "path" => "login.php",
          "inputs" =>
            obj([
              {"username", "{{ .Config.username }}"},
              {"password", "{{ .Config.password }}"}
            ]),
          "selectorinputs" =>
            obj([
              {"formtoken", %{"selector" => ~s|input[name="formtoken"]|, "attribute" => "value"}}
            ]),
          "test" => %{"selector" => ~s|a[href*="logout"]|}
        })

      form_site(landing, "/index.php")

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      assert [
               {"nyaa.test", "GET", "/login.php", "", ""},
               {"nyaa.test", "POST", "/index.php", "view=Login", body},
               {"nyaa.test", "GET", "/", _, _}
             ] = wire()

      assert body == "username=frieren&password=#{@password}&formtoken=ft1"
      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]
    end

    for {optional, outcome} <- [{true, "is left out"}, {false, "fails the login"}] do
      test "a selector input with optional #{optional} that matches nothing #{outcome}" do
        indexer =
          login!(%{
            "method" => "form",
            "path" => "login.php",
            "inputs" => obj([{"user_x", "{{ .Config.username }}"}]),
            "selectorinputs" =>
              obj([
                {"csrf", %{"selector" => ~s|input[name="tok"]|, "attribute" => "value"}},
                {"gone",
                 %{
                   "selector" => ~s|input[name="absent"]|,
                   "attribute" => "value",
                   "optional" => unquote(optional)
                 }},
                {"key", %{"selector" => "span#key"}}
              ]),
            "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
          })

        form_site(landing(), "/takelogin.php")
        answer = Native.search_tv_query("frieren", categories: [5070])

        if unquote(optional) do
          assert {:ok, [_row], _report} = answer

          assert [
                   {"nyaa.test", "GET", "/login.php", "", ""},
                   {"nyaa.test", "POST", "/takelogin.php", "", body},
                   {"nyaa.test", "GET", "/", _, _}
                 ] = wire()

          # The selector inputs the form lacks follow it in file order.
          assert body == "user_x=frieren&pass_x=&remember=1&r=b&tok=t0k3n&csrf=t0k3n&key=k3y"
        else
          assert {:error, {:no_indexer_answered, report}} = answer
          assert outcomes(report) == %{indexer.id => {:failed, :bad_response}}
          assert [{"nyaa.test", "GET", "/login.php", "", ""}] = wire()
        end
      end
    end

    test "a landing page with no such form fails the login and sends no submit" do
      indexer =
        login!(%{
          "method" => "form",
          "path" => "login.php",
          "form" => "form#absent",
          "inputs" => obj([{"user_x", "{{ .Config.username }}"}])
        })

      form_site(landing(), "/takelogin.php")

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :bad_response}}
      assert [{"nyaa.test", "GET", "/login.php", "", ""}] = wire()
      refute status(indexer).credentials_rejected
    end

    @tag :tmp_dir
    test "a worker that crashes on the landing page records the worker failure", %{tmp_dir: tmp} do
      indexer =
        login!(%{
          "method" => "form",
          "path" => "login.php",
          "inputs" => obj([{"user_x", "{{ .Config.username }}"}])
        })

      form_site(landing(), "/takelogin.php")
      crashing_worker!(tmp)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :parser_failed}}
      assert [{"nyaa.test", "GET", "/login.php", "", ""}] = wire()

      status = status(indexer)
      assert {status.last_failure, status.credentials_rejected} == {:parser_failed, false}
    end
  end

  describe "rejected credentials" do
    test "a 401 login answer rejects them; a second search sends nothing; a passing Test ends it" do
      indexer = login!(post_login())

      site(fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert [{"POST", "/login.php", _, _}] = sent()

      status = status(indexer)
      assert {status.credentials_rejected, status.credentials_rejected_by} == {true, :login_post}
      assert stored(indexer) == :miss

      # A second search sends the indexer nothing.
      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert sent() == []

      # The Test asks whatever the state, and a passing Test ends it.
      site()
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert %{"/login.php" => 1, "/" => 1} = counts(sent())
      refute status(indexer).credentials_rejected
    end

    test "a login.error selector that matches the login answer rejects them" do
      indexer = login!(post_login())

      site(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, ~s|<html><body><div class="error">Wrong</div></body></html>|)
      end)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert status(indexer).credentials_rejected_by == :login_post
      assert stored(indexer) == :miss
    end

    test "a refused Test login reads as a login rejection on the Test" do
      indexer = login!(post_login())
      site(fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)

      assert {:ok, %{outcome: :login_rejected}} = Native.test_indexer(indexer.id)
      assert status(indexer).credentials_rejected_by == :login_post
    end

    for {sign, answer} <- [
          {"a redirect", quote(do: {:redirect, 302, "https://nyaa.test/login.php"})},
          {"an HTTP 401", quote(do: {401, "no"})},
          {"a page the test selector matches nothing on", quote(do: nyaa_page(frieren()))}
        ] do
      test "a resend that still shows #{sign} rejects them after one login" do
        indexer = login!(post_login())

        route(%{
          "nyaa.test" => fn conn, _query ->
            case conn.request_path do
              "/login.php" -> with_cookie(conn, "sid=s3ss10n")
              "/" -> unquote(answer)
            end
          end
        })

        stored!(indexer)

        assert {:error, {:no_indexer_answered, report}} =
                 Native.search_tv_query("frieren", categories: [5070])

        assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
        assert counts(sent()) == %{"/" => 2, "/login.php" => 1}
        assert status(indexer).credentials_rejected_by == :login_post
      end
    end
  end

  describe "when to log in" do
    test "a login sign logs in once and sends the request again once" do
      indexer = login!(post_login())
      site()
      stored!(indexer)

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert [
               {"GET", "/", "sid=0ld", _},
               {"POST", "/login.php", "", _},
               {"GET", "/", "sid=s3ss10n", _}
             ] = sent()

      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]
    end

    test "a search answered 503 twice records a failure and sends no login" do
      indexer = login!(post_login())
      route(%{"nyaa.test" => fn _conn, _query -> {503, "down"} end})
      stored!(indexer)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, {:http_status, 503}}}
      assert counts(sent()) == %{"/" => 2}

      status = status(indexer)
      assert {status.backoff, status.credentials_rejected} == {:failure, false}
    end

    for {class, answer} <- [
          {"HTTP 403", quote(do: {403, "no"})},
          {"HTTP 404", quote(do: {404, "gone"})},
          {"HTTP 408", quote(do: {408, "slow"})},
          {"a timeout", quote(do: {:transport, :timeout})},
          {"no connection", quote(do: {:transport, :econnrefused})}
        ] do
      test "a search answered #{class} records a failure and sends no login" do
        indexer = login!(post_login())

        route(%{
          "nyaa.test" => fn conn, _query ->
            case conn.request_path do
              "/login.php" -> flunk("#{unquote(class)} started a login")
              "/" -> unquote(answer)
            end
          end
        })

        stored!(indexer)

        assert {:error, {:no_indexer_answered, _report}} =
                 Native.search_tv_query("frieren", categories: [5070])

        refute Map.has_key?(counts(sent()), "/login.php")

        status = status(indexer)
        assert {status.backoff, status.credentials_rejected} == {:failure, false}
      end
    end

    test "a search answered 429 records a limit and sends no login" do
      indexer = login!(post_login())
      route(%{"nyaa.test" => fn _conn, _query -> {429, "slow down"} end})
      stored!(indexer)

      assert {:error, _reason} = Native.search_tv_query("frieren", categories: [5070])
      assert counts(sent()) == %{"/" => 1}

      status = status(indexer)
      assert {status.backoff, status.credentials_rejected} == {:limit, false}
    end

    test "a resend answered 503 after a login records a failure, not rejected credentials" do
      indexer = login!(post_login())
      test_pid = self()

      route(%{
        "nyaa.test" => fn conn, _query ->
          case conn.request_path do
            "/login.php" ->
              send(test_pid, :logged_in)
              with_cookie(conn, "sid=s3ss10n")

            "/" ->
              if cookie(conn) =~ "s3ss10n",
                do: {503, "down"},
                else: {:redirect, 302, "https://nyaa.test/login.php"}
          end
        end
      })

      stored!(indexer)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, {:http_status, 503}}}
      assert_received :logged_in
      assert counts(sent()) == %{"/" => 3, "/login.php" => 1}

      status = status(indexer)
      assert {status.backoff, status.credentials_rejected} == {:failure, false}
    end

    test "a page whose content type is not HTML shows no login sign" do
      indexer = login!(post_login())
      route(%{"nyaa.test" => fn _conn, _query -> {200, "application/json", "{}"} end})
      stored!(indexer)

      assert {:ok, [], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
      assert counts(sent()) == %{"/" => 1}
    end

    @tag :tmp_dir
    test "a worker that crashes on the login test probe records the worker failure, no login",
         %{tmp_dir: tmp} do
      indexer = login!(post_login())
      site()
      stored!(indexer, "sid=s3ss10n")
      crashing_worker!(tmp)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :parser_failed}}
      assert counts(sent()) == %{"/" => 1}
      refute status(indexer).credentials_rejected
    end

    @tag :tmp_dir
    test "a worker that crashes on the login answer records the worker failure, not a rejection",
         %{tmp_dir: tmp} do
      indexer = login!(post_login())
      site()
      crashing_worker!(tmp)

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :parser_failed}}
      assert counts(sent()) == %{"/login.php" => 1}
      assert stored(indexer) == :miss
      refute status(indexer).credentials_rejected
    end

    test "a login another search made while this one waited is used, with no request" do
      indexer = login!(post_login())
      site()
      {:ok, copy} = Cardigann.copy(indexer)

      # The other search's login lands while this one waits for the slot.
      hold = fn fun ->
        stored!(indexer, "sid=fresh", DateTime.add(@now, 1, :second))
        {:ran, fun.()}
      end

      run = %{
        indexer: indexer,
        copy: copy,
        context: %{deadline_at: System.monotonic_time(:millisecond) + 10_000},
        hold: hold,
        record?: true
      }

      assert {:ok, %{jar: jar, logged_in?: true}} =
               Session.login(run, nil)

      assert Jar.to_list(jar) == [["https", "nyaa.test", 443, "sid", "fresh"]]
      assert sent() == []
    end

    test "a search makes one login: a later page's login sign after it rejects the credentials" do
      paths = [
        %{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}, {"p", "1"}])},
        %{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }} x"}, {"p", "2"}])}
      ]

      indexer = login!(post_login(), &put_in(&1, ["search", "paths"], paths))

      route(%{
        "nyaa.test" => fn conn, query ->
          case {conn.request_path, query["p"]} do
            {"/login.php", _} -> with_cookie(conn, "sid=s3ss10n")
            {"/", "1"} -> session_page()
            {"/", "2"} -> {:redirect, 302, "https://nyaa.test/login.php"}
          end
        end
      })

      # The first page's row comes back beside the rejection, and the search reads incomplete
      # (#1738).
      assert {:ok, [%{title: "[Group] Frieren - 01 [1080p]", indexer_id: id}], report} =
               Native.search_tv_query("frieren", categories: [5070])

      assert id == indexer.id
      assert Report.incomplete?(report)

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert counts(sent()) == %{"/login.php" => 1, "/" => 2}
      assert status(indexer).credentials_rejected_by == :login_post
    end

    test "each login request takes its own slot of the lease, spaced as the search's" do
      indexer = login!(post_login())
      site()
      test_pid = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:cinder, :native, :lease, :spaced],
        fn _event, measure, meta, _ ->
          send(test_pid, {:spaced, meta.key, measure.spacing_ms})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      # One slot for the login, one for the search page: the lease's 10 ms in the test env.
      assert_received {:spaced, key, 10} when key == indexer.id
      assert_received {:spaced, key, 10} when key == indexer.id
      refute_received {:spaced, _key, _ms}
    end

    for {failure, answer, reason} <- [
          {"a transport error", quote(do: {:transport, :econnrefused}), :connection_refused},
          {"an HTTP 503", quote(do: {503, "down"}), {:http_status, 503}}
        ] do
      test "#{failure} on the login request records a failure, with no retry" do
        indexer = login!(post_login())

        route(%{
          "nyaa.test" => fn conn, _query ->
            case conn.request_path do
              "/login.php" -> unquote(answer)
              "/" -> session_page()
            end
          end
        })

        assert {:error, {:no_indexer_answered, report}} =
                 Native.search_tv_query("frieren", categories: [5070])

        assert outcomes(report) == %{indexer.id => {:failed, unquote(Macro.escape(reason))}}
        assert counts(sent()) == %{"/login.php" => 1}

        status = status(indexer)
        assert {status.backoff, status.credentials_rejected} == {:failure, false}
      end
    end
  end

  describe "hosts and credentials" do
    test "a login redirect to another host gets no cookie, no secret and no Referer" do
      indexer = login!(post_login())

      route(%{
        "nyaa.test" => fn conn, _query ->
          case conn.request_path do
            "/login.php" ->
              conn
              |> Plug.Conn.put_resp_header("set-cookie", "sid=s3ss10n; path=/")
              |> Plug.Conn.put_resp_header("location", "https://other.test/welcome")
              |> Plug.Conn.send_resp(302, "")

            "/" ->
              if cookie(conn) == "sid=s3ss10n",
                do: session_page(),
                else: {:redirect, 302, "https://nyaa.test/login.php"}
          end
        end,
        "other.test" => fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "evil=1; path=/")
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, "<html><body>hi</body></html>")
        end
      })

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      assert_received {:cardigann_request, "other.test", "/welcome", query, headers}
      assert query == %{}
      refute Enum.any?(headers, fn {name, _value} -> name in ["cookie", "referer"] end)
      refute inspect(headers) =~ @password
      assert_received {:cardigann_wire, "other.test", "GET", "/welcome", "", ""}

      # The other host's `Set-Cookie` never entered the jar.
      assert stored(indexer) == [["https", "nyaa.test", 443, "sid", "s3ss10n"]]
    end

    test "a 307 that would carry a login body to another host is never followed" do
      # The one input is the password with its dashes cut: no form of a secret that the secret
      # check reads, so only the rule for a hop that keeps the body stops the 307.
      masked = ~S|{{ re_replace .Config.password "-" "" }}|
      indexer = login!(post_login(%{"inputs" => obj([{"p", masked}])}))

      route(%{
        "nyaa.test" => fn _conn, _query -> {:redirect, 307, "https://other.test/takelogin"} end,
        "other.test" => fn _conn, _query -> flunk("the login body left the credential hosts") end
      })

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :secret_host}}
      assert counts(sent()) == %{"/login.php" => 1}
    end

    # A URL the definition holds makes its host a credential host
    # (`Cinder.Indexers.Definitions.CredentialHosts`), so the other host comes from the site.
    # The input is the password with its dashes cut, which the secret check does not read, so
    # only the rule that a login's inputs go to a credential host stops the submit.
    test "a form whose action names another host is never submitted" do
      indexer =
        login!(%{
          "method" => "form",
          "path" => "login.php",
          "inputs" => obj([{"user_x", ~S|{{ re_replace .Config.password "-" "" }}|}])
        })

      landing =
        ~s|<html><body><form action="https://other.test/takelogin.php"><input name="a"></form></body></html>|

      route(%{
        "nyaa.test" => fn _conn, _query -> landing end,
        "other.test" => fn _conn, _query -> flunk("the submit left the credential hosts") end
      })

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :secret_host}}
      assert [{"nyaa.test", "GET", "/login.php", "", ""}] = wire()
    end

    test "an indexer whose secrets do not decrypt sends no login request" do
      indexer = login!(post_login())
      site()

      # The positive control: with secrets that decrypt, the indexer logs in.
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert %{"/login.php" => 1} = counts(sent())

      Repo.delete_all(IndexerCookies)
      Cinder.DefinitionFixtures.undecryptable!(indexer)

      assert Native.search_tv_query("frieren", categories: [5070]) == {:error, :no_indexers}
      assert sent() == []
    end

    test "login requests send login.headers, else the templated search.headers" do
      with_search_headers = fn definition ->
        put_in(definition, ["search", "headers"], %{
          "Authorization" => ["Basic {{ .Config.username }}"]
        })
      end

      login!(post_login(), with_search_headers)
      site()

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:cardigann_request, "nyaa.test", "/login.php", _query, headers}
      assert {"authorization", "Basic frieren"} in headers
    end

    test "a login whose headers do not render sends nothing and records a failure" do
      bad_header = &put_in(&1, ["login", "headers"], %{"X-Login" => ["{{ .Config.username }}"]})
      secrets = %{"username" => "frie\u0001ren", "password" => @password}
      indexer = login!(post_login(), bad_header, secrets)
      site()

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :definition_error}}
      assert sent() == []

      status = status(indexer)

      assert {status.backoff, status.last_failure, status.credentials_rejected} ==
               {:failure, :definition_error, false}
    end

    test "login.headers win over search.headers on a login request" do
      with_both = fn definition ->
        definition
        |> put_in(["search", "headers"], %{"Authorization" => ["Basic search"]})
        |> put_in(["login", "headers"], %{"X-Login" => ["{{ .Config.username }}"]})
      end

      login!(post_login(), with_both)
      site()

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:cardigann_request, "nyaa.test", "/login.php", _query, headers}
      assert {"x-login", "frieren"} in headers
      refute Enum.any?(headers, &(elem(&1, 0) == "authorization"))
    end

    test "a login answered 429 echoing the password, then a failed call, keep it out of every error and log" do
      indexer = login!(post_login())
      test_pid = self()
      calls = :counters.new(1, [])

      route(%{
        "nyaa.test" => fn conn, _query ->
          send(test_pid, {:login_body, conn.adapter |> elem(1) |> Map.get(:raw_body)})
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) > 1 do
            Req.Test.transport_error(conn, :econnrefused)
          else
            conn
            |> Plug.Conn.put_resp_header("x-echo", @password)
            |> Plug.Conn.put_resp_header("retry-after", "60")
            |> Plug.Conn.send_resp(429, "rate limited for password #{@password}")
          end
        end
      })

      # Every level: the global level goes to :debug, as `Cinder.IndexersLogTest` sets it, since
      # the capture alone holds only what the suite's level lets through.
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          answer = Native.search_tv_query("frieren", categories: [5070])
          refute inspect(answer) =~ @password
          assert {:error, _reason} = answer

          test = Native.test_indexer(indexer.id)
          refute inspect(test) =~ @password
        end)

      Logger.configure(level: level)
      assert_received {:login_body, body}
      assert body =~ @password
      # The control: the capture holds the debug lines of the status writes.
      assert log =~ "[debug]"
      assert log =~ "native_indexer_status"
      refute log =~ @password
      refute inspect(status(indexer)) =~ @password
    end
  end

  describe "a grab" do
    @magnet "magnet:?xt=urn:btih:#{String.duplicate("ab", 20)}&dn=Movie"
    @details "https://t9.test/torrent/1"

    defp t9_login!(login) do
      definition =
        torrent9_like(fn definition ->
          definition
          |> Map.put("type", "private")
          |> Map.update!("settings", fn settings ->
            [
              %{"name" => "username", "type" => "text", "label" => "Username"},
              %{"name" => "password", "type" => "password", "label" => "Password"}
              | settings
            ]
          end)
          |> Map.put("login", login)
        end)

      [indexer] = setup!([{"t9.yml", definition}], [{"t9.yml", torrent9_base(), @secrets}])
      indexer
    end

    defp grab(indexer) do
      Native.fetch_download(@details, nil,
        max_bytes: 1024 * 1024,
        error_tag: :torrent_fetch_status,
        allow_magnet: true,
        indexer_source: "native",
        indexer_id: indexer.id,
        credentials_version: indexer.credentials_version
      )
    end

    # The details page answers its magnet link with the session cookie, and redirects to the
    # login page without it.
    defp t9_site(login_answer \\ &with_cookie(&1, "sid=s3ss10n")) do
      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/login.php" ->
              login_answer.(conn)

            "/torrent/1" ->
              if cookie(conn) =~ "sid=s3ss10n",
                do: torrent9_details(link: @magnet),
                else: {:redirect, 302, "https://t9.test/login"}
          end
        end
      })
    end

    defp stored_t9!(indexer) do
      jar = Jar.put_string(Jar.new(), URI.parse(torrent9_base()), "sid=0ld")
      assert IndexerCookies.store_login(indexer, jar, @now) == :written
    end

    test "a details page that shows a login sign logs in once and grabs" do
      indexer = t9_login!(post_login())
      t9_site()
      stored_t9!(indexer)

      assert grab(indexer) == {:magnet, @magnet}

      assert [
               {"GET", "/torrent/1", "sid=0ld", _},
               {"POST", "/login.php", "", login_body},
               {"GET", "/torrent/1", "sid=s3ss10n", _}
             ] = sent()

      assert login_body =~ "password=#{@password}"

      assert {:ok, %{jar: jar}} = IndexerCookies.read(indexer, @now)
      assert Jar.to_list(jar) == [["https", "t9.test", 443, "sid", "s3ss10n"]]
    end

    login_form =
      ~s|<html><body><form action="/login.php" method="post"><input name="username">| <>
        ~s|<input type="password" name="password"></form></body></html>|

    for {sign, answer} <- [
          {"an HTTP 401", {401, "text/html", "<html><body>Log in</body></html>"}},
          {"a login page", {200, "text/html", login_form}}
        ] do
      test "a details page that answers #{sign} logs in once and grabs" do
        indexer = t9_login!(post_login())
        {status, type, body} = unquote(Macro.escape(answer))

        route(%{
          "t9.test" => fn conn, _query ->
            case conn.request_path do
              "/login.php" ->
                with_cookie(conn, "sid=s3ss10n")

              "/torrent/1" ->
                if cookie(conn) =~ "sid=s3ss10n",
                  do: torrent9_details(link: @magnet),
                  else: {status, type, body}
            end
          end
        })

        stored_t9!(indexer)

        assert grab(indexer) == {:magnet, @magnet}

        assert [
                 {"GET", "/torrent/1", "sid=0ld", _},
                 {"POST", "/login.php", "", _},
                 {"GET", "/torrent/1", "sid=s3ss10n", _}
               ] = sent()

        refute status(indexer).credentials_rejected
      end
    end

    test "with no stored session the grab logs in first" do
      indexer = t9_login!(post_login())
      t9_site()

      assert grab(indexer) == {:magnet, @magnet}
      assert [{"POST", "/login.php", "", _}, {"GET", "/torrent/1", "sid=s3ss10n", _}] = sent()
    end

    test "a refused login is :indexer_auth_failed, and the next grab sends nothing" do
      indexer = t9_login!(post_login())
      t9_site(fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert [{"POST", "/login.php", "", _}] = sent()

      status = status(indexer)
      assert {status.credentials_rejected, status.credentials_rejected_by} == {true, :login_post}

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert sent() == []
    end

    test "a login sign after the grab's login is :indexer_auth_failed" do
      indexer = t9_login!(post_login())

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/login.php" -> with_cookie(conn, "sid=s3ss10n")
            "/torrent/1" -> {:redirect, 302, "https://t9.test/login"}
          end
        end
      })

      stored_t9!(indexer)

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert counts(sent()) == %{"/torrent/1" => 2, "/login.php" => 1}
      assert status(indexer).credentials_rejected_by == :login_post
    end

    test "a details page's Set-Cookie from the site updates the stored jar" do
      indexer = t9_login!(post_login())

      route(%{
        "t9.test" => fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "seen=2; path=/")
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, torrent9_details(link: @magnet))
        end
      })

      jar = Jar.put_string(Jar.new(), URI.parse(torrent9_base()), "sid=s3ss10n")
      assert IndexerCookies.store_login(indexer, jar, @now) == :written

      assert grab(indexer) == {:magnet, @magnet}
      assert [{"GET", "/torrent/1", "sid=s3ss10n", _}] = sent()

      assert {:ok, %{jar: jar}} = IndexerCookies.read(indexer, @now)

      assert Jar.to_list(jar) == [
               ["https", "t9.test", 443, "seen", "2"],
               ["https", "t9.test", 443, "sid", "s3ss10n"]
             ]
    end

    test "a login answered 503 is a capped grab failure, recorded as the indexer's failure" do
      indexer = t9_login!(post_login())
      t9_site(fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert grab(indexer) == {:error, {:cardigann_grab, :login_failed}}
      assert [{"POST", "/login.php", "", _}] = sent()

      status = status(indexer)

      assert {status.backoff, status.last_failure, status.credentials_rejected} ==
               {:failure, :http_status, false}
    end

    test "a login answered 429 is the indexer's limit, recorded and answered as one" do
      indexer = t9_login!(post_login())

      t9_site(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "600")
        |> Plug.Conn.send_resp(429, "slow")
      end)

      assert {:error, {:indexer_limit, %DateTime{} = until}} = grab(indexer)
      assert [{"POST", "/login.php", "", _}] = sent()

      status = status(indexer)

      assert {status.backoff, status.backoff_until, status.credentials_rejected} ==
               {:limit, until, false}
    end
  end

  describe "cookie rows" do
    test "a row of an older credentials_version is deleted and the next request logs in" do
      indexer = login!(post_login())
      site()
      stored!(indexer, "sid=s3ss10n")

      {1, _} =
        Repo.update_all(
          from(c in Cinder.Indexers.ConfiguredIndexer, where: c.id == ^indexer.id),
          inc: [credentials_version: 1]
        )

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"POST", "/login.php", "", _}, {"GET", "/", "sid=s3ss10n", _}] = sent()

      fresh = Repo.get!(Cinder.Indexers.ConfiguredIndexer, indexer.id)

      assert Repo.get!(IndexerCookies, indexer.id).credentials_version ==
               fresh.credentials_version
    end

    test "an expired row logs in again and leaves the health state unchanged" do
      indexer = login!(post_login())
      site()
      stored!(indexer, "sid=s3ss10n", DateTime.add(@now, -31, :day))

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"POST", "/login.php", "", _}, {"GET", "/", "sid=s3ss10n", _}] = sent()

      status = status(indexer)
      assert {status.last_failure, status.failures_in_row, status.backoff} == {nil, 0, :none}
    end

    test "a row that does not decrypt logs in again and leaves the health state unchanged" do
      indexer = login!(post_login())
      site()
      stored!(indexer, "sid=s3ss10n")
      {1, _} = Repo.update_all(IndexerCookies, set: [ciphertext: "not-a-ciphertext"])

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"POST", "/login.php", "", _}, {"GET", "/", "sid=s3ss10n", _}] = sent()

      status = status(indexer)
      assert {status.last_failure, status.failures_in_row, status.backoff} == {nil, 0, :none}
    end

    test "a search answer's Set-Cookie from the site updates the stored jar" do
      indexer = login!(post_login())

      route(%{
        "nyaa.test" => fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "seen=2; path=/")
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, session_page())
        end
      })

      stored!(indexer, "sid=s3ss10n")

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      assert stored(indexer) == [
               ["https", "nyaa.test", 443, "seen", "2"],
               ["https", "nyaa.test", 443, "sid", "s3ss10n"]
             ]
    end
  end
end
