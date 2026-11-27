defmodule Cinder.Acquisition.Indexer.CardigannCaptchaTest do
  # The Cardigann image captcha (#1681) through the real `Cinder.Acquisition.IndexerSource.Native`,
  # on definitions written for Cinder (`Cinder.CardigannFixtures`), behind the
  # `Cinder.CardigannStub` plug. Every page runs through a real parser worker.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.{Native, Report}

  alias Cinder.Acquisition.IndexerSource.Native.{
    IndexerCaptchas,
    IndexerCookies,
    IndexerState,
    IndexerStatus
  }

  alias Cinder.ConfigCase
  alias Cinder.Indexers.Definitions
  alias Cinder.Repo

  @now ~U[2026-11-26 12:00:00Z]
  @password "pw-Secret-91"
  @secrets %{"username" => "frieren", "password" => @password}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  # --- the definitions ---

  defp private(definition) do
    definition
    |> Map.put("type", "private")
    |> Map.update!("settings", fn settings ->
      [
        %{"name" => "username", "type" => "text", "label" => "Username"},
        %{"name" => "password", "type" => "password", "label" => "Password"}
        | settings
      ]
    end)
  end

  defp captcha_login(extra \\ %{}) do
    Map.merge(
      %{
        "method" => "form",
        "path" => "login.php",
        "inputs" =>
          obj([
            {"username", "{{ .Config.username }}"},
            {"password", "{{ .Config.password }}"}
          ]),
        "captcha" => %{"type" => "image", "selector" => "img#captcha", "input" => "imagestring"},
        "error" => [%{"selector" => "div.error"}],
        "test" => %{"path" => "my.php", "selector" => ~s|a[href*="logout"]|}
      },
      extra
    )
  end

  defp captcha!(login \\ captcha_login()) do
    definition = nyaa_like(&(&1 |> private() |> Map.put("login", login)))
    [indexer] = setup!([{"captcha.yml", definition}], [{"captcha.yml", nyaa_base(), @secrets}])
    indexer
  end

  # --- the site ---

  defp landing(captcha) do
    """
    <!doctype html><html><body>
    <form action="/takelogin.php" method="post">
      <input name="username" value=""><input type="password" name="password">
      <input type="hidden" name="tok" value="t0k3n">
      #{captcha}
    </form>
    </body></html>
    """
  end

  @captcha_img ~s|<img id="captcha" src="/captcha.php?id=7" alt="">|

  defp session_page,
    do:
      String.replace(
        nyaa_page([
          %{
            title: "[Group] Frieren - 01 [1080p]",
            magnet: "magnet:?xt=urn:btih:" <> String.duplicate("1", 40),
            size: "1.4 GiB",
            date: "2026-11-25 10:30",
            cat: "1_2"
          }
        ]),
        "<body>",
        ~s|<body><a href="/logout.php">Log out</a>|
      )

  defp with_cookie(conn, cookie) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", cookie <> "; path=/; HttpOnly")
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<!doctype html><html><body><p>Welcome</p></body></html>")
  end

  defp cookie(conn), do: conn |> Plug.Conn.get_req_header("cookie") |> Enum.join("; ")

  # The site: `/login.php` answers `landing`, `/takelogin.php` sets the session cookie, and the
  # search page answers with it and redirects to the login page without it.
  defp site(landing, extra \\ %{}) do
    route(%{
      "nyaa.test" => fn conn, _query ->
        case Map.get(extra, conn.request_path) do
          nil ->
            case conn.request_path do
              "/login.php" ->
                with_cookie_header(conn, "landing=l4nd", landing)

              "/takelogin.php" ->
                with_cookie(conn, "sid=s3ss10n")

              "/" ->
                if cookie(conn) =~ "sid=s3ss10n",
                  do: session_page(),
                  else: {:redirect, 302, "https://nyaa.test/login.php"}
            end

          answer ->
            answer.(conn)
        end
      end
    })
  end

  defp with_cookie_header(conn, cookie, body) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", cookie <> "; path=/")
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  defp paths, do: for({_host, method, path, _query, _body} <- wire(), do: {method, path})

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  defp state(indexer), do: Enum.find(IndexerState.list(@now), &(&1.id == indexer.id)).state

  describe "an automatic login that meets a captcha" do
    test "a search stops before the submit, records :captcha_required, and the next search sends nothing" do
      indexer = captcha!()
      site(landing(@captcha_img))

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert paths() == [{"GET", "/login.php"}]

      status = status(indexer)
      assert {status.credentials_rejected, status.credentials_rejected_by} == {true, :captcha}
      assert state(indexer) == {:credentials_rejected, :captcha_required}
      assert IndexerState.needs_admin?(state(indexer))

      assert {:error, {:no_indexer_answered, report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      assert paths() == []
    end

    test "a captcha element with no src stops the login too" do
      indexer = captcha!()
      site(landing(~s|<img id="captcha">|))

      assert {:error, {:no_indexer_answered, _report}} =
               Native.search_tv_query("frieren", categories: [5070])

      assert paths() == [{"GET", "/login.php"}]
      assert status(indexer).credentials_rejected_by == :captcha
    end

    # Some sites show the captcha only sometimes: the positive control of the two tests above.
    test "a landing page with no captcha element logs in as #1680 does" do
      indexer = captcha!()
      site(landing(~s|<img id="logo" src="/logo.png">|))

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert paths() == [{"GET", "/login.php"}, {"POST", "/takelogin.php"}, {"GET", "/"}]

      refute status(indexer).credentials_rejected
    end

    test "a Test with no answer stops too and records :captcha_required as its outcome" do
      indexer = captcha!()
      site(landing(@captcha_img))

      assert {:ok, %{outcome: :captcha_required}} = Native.test_indexer(indexer.id)
      assert paths() == [{"GET", "/login.php"}]
      assert status(indexer).credentials_rejected_by == :captcha
    end
  end

  describe "a captcha load" do
    @png <<0x89, "PNG\r\n", 0x1A, "\n", "png-body">>

    defp image_site(answer, captcha \\ @captcha_img) do
      site(landing(captcha), %{
        "/captcha.php" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "img=1m4g3; path=/")
          |> Plug.Conn.put_resp_header("content-type", "image/png")
          |> Plug.Conn.send_resp(200, answer)
        end
      })
    end

    defp captcha_binding(indexer) do
      %{address: nyaa_base(), blob_sha: Definitions.running_blob_sha(indexer.id)}
    end

    test "fetches the image with the landing page's cookies and stores the session" do
      indexer = captcha!()
      image_site(@png)

      assert {:ok, %{token: token, mime: "image/png", image: image}} =
               Native.load_captcha(indexer.id)

      assert Base.decode64!(image) == @png

      assert_received {:cardigann_request, "nyaa.test", "/captcha.php", %{"id" => "7"}, headers}
      assert {"cookie", "landing=l4nd"} in headers
      assert {"referer", "https://nyaa.test/login.php"} in headers
      assert paths() == [{"GET", "/login.php"}, {"GET", "/captcha.php"}]

      assert IndexerCaptchas.live?(indexer.id, token, captcha_binding(indexer), @now)
      # A load is no login answer: the status is as it was.
      refute status(indexer).credentials_rejected
    end

    test "reads JPEG, GIF and WebP by their first bytes, whatever the content type says" do
      at_cap = @png <> :binary.copy("x", 1_048_576 - byte_size(@png))

      for {bytes, mime} <- [
            {at_cap, "image/png"},
            {<<0xFF, 0xD8, 0xFF, 0xE0, "jpeg">>, "image/jpeg"},
            {"GIF87a-gif", "image/gif"},
            {"GIF89a-gif", "image/gif"},
            {"RIFF" <> <<1, 2, 3, 4>> <> "WEBPVP8 ", "image/webp"}
          ] do
        indexer = captcha!()
        image_site(bytes)

        assert {:ok, %{mime: ^mime, image: image}} = Native.load_captcha(indexer.id)
        assert Base.decode64!(image) == bytes
      end
    end

    test "an answer that is no image, or past 1 MiB, stores no session" do
      too_large = @png <> :binary.copy("x", 1_048_577 - byte_size(@png))

      for {answer, error} <- [
            {"<html><body>Not an image</body></html>", {:captcha_image, :type}},
            {~s|<svg xmlns="http://www.w3.org/2000/svg"><text>42</text></svg>|,
             {:captcha_image, :type}},
            {"RIFF" <> <<1, 2, 3, 4>> <> "WAVEfmt ", {:captcha_image, :type}},
            {too_large, {:captcha_image, :too_large}},
            {:binary.copy("x", 3 * 1024 * 1024), {:captcha_image, :too_large}}
          ] do
        indexer = captcha!()
        image_site(answer)

        assert Native.load_captcha(indexer.id) == {:error, error}
        assert Repo.get(IndexerCaptchas, indexer.id) == nil
      end
    end

    # The positive control of this test is the first test of this block.
    test "an image on another host gets neither the site's cookies nor its Referer" do
      indexer = captcha!()
      page = landing(~s|<img id="captcha" src="https://cdn.test/c.png">|)

      route(%{
        "nyaa.test" => fn conn, _query -> with_cookie_header(conn, "landing=l4nd", page) end,
        "cdn.test" => fn _conn, _query -> {200, "image/png", @png} end
      })

      assert {:ok, %{mime: "image/png"}} = Native.load_captcha(indexer.id)
      assert_received {:cardigann_request, "cdn.test", "/c.png", _query, headers}
      refute List.keymember?(headers, "cookie", 0)
      refute List.keymember?(headers, "referer", 0)
    end

    test "a page with no captcha, or a captcha with no src, is :captcha_not_found" do
      for captcha <- [~s|<img id="logo" src="/logo.png">|, ~s|<img id="captcha">|] do
        indexer = captcha!()
        image_site(@png, captcha)

        assert Native.load_captcha(indexer.id) == {:error, :captcha_not_found}
        assert paths() == [{"GET", "/login.php"}]
        assert Repo.get(IndexerCaptchas, indexer.id) == nil
      end
    end

    test "the session reads live after its load, and not past 5 minutes or under another base URL" do
      indexer = captcha!()
      image_site(@png)
      assert {:ok, %{token: token}} = Native.load_captcha(indexer.id)

      assert Native.captcha_live?(indexer.id, token)
      refute Native.captcha_live?(indexer.id, "another-token")
      refute Native.captcha_live?(indexer.id + 1000, token)

      ConfigCase.put_env(Native, clock: fn -> DateTime.add(@now, 300, :second) end)
      refute Native.captcha_live?(indexer.id, token)

      ConfigCase.put_env(Native, clock: fn -> @now end)
      assert Native.captcha_live?(indexer.id, token)

      Repo.update_all(
        Ecto.Query.from(c in Cinder.Indexers.ConfiguredIndexer, where: c.id == ^indexer.id),
        set: [base_url: "https://mirror.nyaa.test/"]
      )

      refute Native.captcha_live?(indexer.id, token)
    end

    test "a definition with no image captcha loads none, with no request" do
      login = Map.delete(captcha_login(), "captcha")
      definition = nyaa_like(&(&1 |> private() |> Map.put("login", login)))
      [indexer] = setup!([{"plain.yml", definition}], [{"plain.yml", nyaa_base(), @secrets}])
      route(%{})

      assert Native.load_captcha(indexer.id) == {:error, :no_captcha}
      assert paths() == []
    end
  end

  describe "a Test that carries the admin's answer" do
    @answer "XyZ12"

    # The site of the captcha load, whose `/takelogin.php` answers `takelogin` when given.
    defp answer_site(takelogin \\ nil, captcha \\ @captcha_img) do
      extra = %{
        "/captcha.php" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "img=1m4g3; path=/")
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @png)
        end
      }

      site(
        landing(captcha),
        if(takelogin, do: Map.put(extra, "/takelogin.php", takelogin), else: extra)
      )
    end

    defp loaded!(indexer) do
      assert {:ok, %{token: token}} = Native.load_captcha(indexer.id)
      _drained = wire()
      token
    end

    defp answered(indexer, token, answer \\ @answer),
      do: Native.test_indexer(indexer.id, captcha: %{token: token, answer: fn -> answer end})

    defp form_body(wire) do
      [body] = for {_host, "POST", "/takelogin.php", _query, body} <- wire, do: body
      URI.decode_query(body)
    end

    test "posts the stored form with the answer and the landing page's cookies, and logs in" do
      indexer = captcha!()
      answer_site()

      # The automatic login met the captcha first.
      assert {:error, _no_answer} = Native.search_tv_query("frieren", categories: [5070])
      assert state(indexer) == {:credentials_rejected, :captcha_required}
      _drained = wire()

      token = loaded!(indexer)
      assert {:ok, %{outcome: :success}} = answered(indexer, token)

      assert_received {:cardigann_request, "nyaa.test", "/takelogin.php", _query, headers}
      assert {"cookie", cookie} = List.keyfind(headers, "cookie", 0)
      assert cookie =~ "landing=l4nd" and cookie =~ "img=1m4g3"
      assert {"referer", "https://nyaa.test/login.php"} in headers

      wire = wire()

      assert for({_host, method, path, _query, _body} <- wire, do: {method, path}) ==
               [{"POST", "/takelogin.php"}, {"GET", "/"}]

      assert form_body(wire) == %{
               "username" => "frieren",
               "password" => @password,
               "tok" => "t0k3n",
               "imagestring" => @answer
             }

      assert Repo.get(IndexerCaptchas, indexer.id) == nil
      refute status(indexer).credentials_rejected

      # The login's cookie row serves the next search, with no login.
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert paths() == [{"GET", "/"}]
    end

    test "with login.selectors on, posts the answer under the name of the element captcha.input selects" do
      login =
        captcha_login(%{
          "selectors" => true,
          "inputs" =>
            obj([
              {~s|input[name="username"]|, "{{ .Config.username }}"},
              {~s|input[type="password"]|, "{{ .Config.password }}"}
            ]),
          "captcha" => %{"type" => "image", "selector" => "img#captcha", "input" => "input.capt"}
        })

      indexer = captcha!(login)
      answer_site(nil, @captcha_img <> ~s|<input class="capt" name="cap_answer_9">|)
      token = loaded!(indexer)

      assert {:ok, %{outcome: :success}} = answered(indexer, token)

      assert form_body(wire()) == %{
               "username" => "frieren",
               "password" => @password,
               "tok" => "t0k3n",
               "cap_answer_9" => @answer
             }
    end

    test "a captured debug log of the load and the answered login holds neither the answer nor a cookie value" do
      indexer = captcha!()
      answer_site()

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          token = loaded!(indexer)
          assert {:ok, %{outcome: :success}} = answered(indexer, token)
        end)

      assert log =~ "native_indexer_captchas"

      for secret <- [@answer, "l4nd", "1m4g3", "s3ss10n", @password] do
        refute log =~ secret
      end
    end

    test "logs in with the answer even when a cookie row is stored" do
      indexer = captcha!()
      jar = Jar.put_string(Jar.new(), URI.parse(nyaa_base()), "sid=s3ss10n")
      assert IndexerCookies.store_login(indexer, jar, @now) == :written
      answer_site()
      token = loaded!(indexer)

      assert {:ok, %{outcome: :success}} = answered(indexer, token)
      assert paths() == [{"POST", "/takelogin.php"}, {"GET", "/"}]
    end

    test "renders the settings at the answer, so a password saved with it is the one posted" do
      indexer = captcha!()
      answer_site()
      token = loaded!(indexer)

      assert {:ok, _updated} =
               Cinder.Indexers.update(nil, indexer.id, indexer.lock_version, %{}, %{
                 "password" => "new-Secret-22"
               })

      assert {:ok, %{outcome: :success}} = answered(indexer, token)
      assert form_body(wire())["password"] == "new-Secret-22"
    end

    test "an answer the site refuses reads as a refused login, and the session is used up" do
      indexer = captcha!()

      answer_site(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          ~s|<html><body><div class="error">Bad captcha</div></body></html>|
        )
      end)

      token = loaded!(indexer)

      assert {:ok, %{outcome: :login_rejected}} = answered(indexer, token)

      assert paths() == [{"POST", "/takelogin.php"}]
      assert Repo.get(IndexerCaptchas, indexer.id) == nil
      assert answered(indexer, token) |> elem(1) |> Map.fetch!(:outcome) == :captcha_expired
    end

    test "a session past its 5 minutes, or another load's token, is :captcha_expired with no request" do
      indexer = captcha!()
      answer_site()
      token = loaded!(indexer)

      ConfigCase.put_env(Native, clock: fn -> DateTime.add(@now, 300, :second) end)
      assert {:ok, %{outcome: :captcha_expired}} = answered(indexer, token)
      assert paths() == []

      ConfigCase.put_env(Native, clock: fn -> @now end)
      old = loaded!(indexer)
      new = loaded!(indexer)
      assert {:ok, %{outcome: :captcha_expired}} = answered(indexer, old)
      assert paths() == []

      # The newer load's session stays for its own answer.
      assert {:ok, %{outcome: :success}} = answered(indexer, new)
    end

    test "a session that does not decrypt, or one copied from another indexer, is :captcha_expired with no request" do
      [one, two] =
        setup!(
          [{"captcha.yml", nyaa_like(&(&1 |> private() |> Map.put("login", captcha_login())))}],
          [{"captcha.yml", nyaa_base(), @secrets}, {"captcha.yml", nyaa_base(), @secrets}]
        )

      answer_site()

      token = loaded!(one)

      Repo.update_all(where(IndexerCaptchas, configured_indexer_id: ^one.id),
        set: [ciphertext: "x"]
      )

      assert {:ok, %{outcome: :captcha_expired}} = answered(one, token)
      assert paths() == []

      token = loaded!(two)
      copied = Repo.get!(IndexerCaptchas, two.id)
      _token = loaded!(one)

      Repo.update_all(where(IndexerCaptchas, configured_indexer_id: ^one.id),
        set: [ciphertext: copied.ciphertext]
      )

      assert {:ok, %{outcome: :captcha_expired}} = answered(one, token)
      assert paths() == []
    end

    # A login header that renders a control character: the login fails before its first request.
    test "a login that fails before its first request deletes the session" do
      login = Map.put(captcha_login(), "headers", %{"X-Login" => ["{{ .Config.username }}"]})
      indexer = captcha!(login)
      answer_site()
      token = loaded!(indexer)

      assert {:ok, _updated} =
               Cinder.Indexers.update(nil, indexer.id, indexer.lock_version, %{}, %{
                 "username" => "frie\u0001ren"
               })

      assert {:ok, %{outcome: :definition_error}} = answered(indexer, token)
      assert paths() == []
      assert Repo.get(IndexerCaptchas, indexer.id) == nil
    end
  end

  describe "a grab that meets a captcha" do
    @details "https://nyaa.test/view/1"

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

    test "is :indexer_auth_failed with no login POST" do
      indexer = captcha!()
      jar = Jar.put_string(Jar.new(), URI.parse(nyaa_base()), "sid=0ld")
      assert IndexerCookies.store_login(indexer, jar, @now) == :written

      site(landing(@captcha_img), %{
        "/view/1" => fn _conn -> {401, "text/html", "<html><body>Log in</body></html>"} end
      })

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert paths() == [{"GET", "/view/1"}, {"GET", "/login.php"}]
      assert status(indexer).credentials_rejected_by == :captcha
    end
  end
end
