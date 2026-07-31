defmodule CinderWeb.ApiControllerTest do
  # async: false — generating the key writes a settings row, and Cinder.Settings.put/2
  # re-applies the global Application env overlay.
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  alias Cinder.ApiKey
  alias Cinder.Issues.IssueReport
  alias Cinder.Repo
  alias Cinder.Requests.Request

  setup :reset_cinder_env

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json"), key: ApiKey.generate()}
  end

  defp authed(conn, key), do: put_req_header(conn, "x-api-key", key)

  defp request_fixture(user, attrs) do
    Repo.insert!(
      struct(
        %Request{
          user_id: user.id,
          target_type: "movie",
          target_id: System.unique_integer([:positive]),
          status: :pending
        },
        attrs
      )
    )
  end

  describe "GET /api/v1/status" do
    test "returns the dashboard counts", %{conn: conn, key: key} do
      user = user_fixture()
      movie_fixture(%{status: :available})
      movie_fixture()
      series_fixture()
      request_fixture(user, %{title: "Heat", status: :pending})
      request_fixture(user, %{title: "Alien", status: :approved})

      Repo.insert!(%IssueReport{
        user_id: user.id,
        target_type: "movie",
        target_id: 603,
        title: "The Matrix",
        category: :playback,
        status: :open
      })

      conn = conn |> authed(key) |> get(~p"/api/v1/status")

      assert json_response(conn, 200) == %{
               "pending_requests" => 1,
               "open_issues" => 1,
               "active_downloads" => 0,
               "movies_total" => 2,
               "movies_available" => 1,
               "series_total" => 1,
               "episodes_wanted" => 0
             }
    end

    test "returns zeroes on an empty install", %{conn: conn, key: key} do
      conn = conn |> authed(key) |> get(~p"/api/v1/status")

      assert json_response(conn, 200)
             |> Map.values()
             |> Enum.all?(&(&1 == 0))
    end
  end

  describe "GET /api/v1/requests" do
    test "returns the queue newest first, with no requester identity", %{conn: conn, key: key} do
      user = user_fixture()
      request_fixture(user, %{title: "Heat", year: 1995, target_id: 949, status: :pending})

      request_fixture(user, %{
        title: "Alien",
        year: 1979,
        target_id: 348,
        status: :denied,
        denial_reason: "not on the household list"
      })

      conn = conn |> authed(key) |> get(~p"/api/v1/requests")
      body = json_response(conn, 200)

      assert %{"total" => 2, "limit" => 50, "offset" => 0} = body
      assert [newest, oldest] = body["requests"]

      assert %{
               "status" => "denied",
               "target_type" => "movie",
               "target_id" => 348,
               "season_number" => nil,
               "title" => "Alien",
               "year" => 1979
             } = newest

      assert is_integer(newest["id"])
      assert is_binary(newest["requested_at"])
      assert oldest["title"] == "Heat"

      # Nothing a non-admin couldn't already see: no requester, no admin prose.
      refute Map.has_key?(newest, "user_id")
      refute Map.has_key?(newest, "denial_reason")
      refute conn.resp_body =~ user.email
      refute conn.resp_body =~ "not on the household list"
    end

    test "paginates on limit/offset", %{conn: conn, key: key} do
      user = user_fixture()
      for n <- 1..3, do: request_fixture(user, %{title: "M#{n}", target_id: n})

      body =
        conn |> authed(key) |> get(~p"/api/v1/requests?limit=2&offset=1") |> json_response(200)

      assert %{"total" => 3, "limit" => 2, "offset" => 1} = body
      assert Enum.map(body["requests"], & &1["title"]) == ["M2", "M1"]
    end

    test "clamps and ignores junk pagination params", %{conn: conn, key: key} do
      user = user_fixture()
      request_fixture(user, %{title: "Heat"})

      for {query, limit, offset} <- [
            {"limit=0&offset=-5", 1, 0},
            {"limit=9999", 100, 0},
            {"limit=abc&offset=%20", 50, 0},
            {"limit[]=2", 50, 0}
          ] do
        body = conn |> authed(key) |> get("/api/v1/requests?" <> query) |> json_response(200)
        assert %{"limit" => ^limit, "offset" => ^offset} = body
      end
    end
  end

  describe "authentication" do
    test "a missing key is 401 and leaks nothing", %{conn: conn} do
      for path <- [~p"/api/v1/status", ~p"/api/v1/requests"] do
        conn = get(conn, path)

        assert json_response(conn, 401) == %{"error" => "unauthorized"}
        assert get_resp_header(conn, "www-authenticate") == []
      end
    end

    test "a wrong key is the same 401 as a missing one", %{conn: conn} do
      missing = conn |> get(~p"/api/v1/status")
      wrong = conn |> authed("nope") |> get(~p"/api/v1/status")

      assert wrong.status == 401
      assert wrong.resp_body == missing.resp_body
    end

    test "a revoked key is 401 and indistinguishable from no key at all", %{conn: conn, key: key} do
      assert conn |> authed(key) |> get(~p"/api/v1/status") |> json_response(200)

      ApiKey.revoke()

      revoked = conn |> authed(key) |> get(~p"/api/v1/status")
      unconfigured = conn |> authed("some-other-key") |> get(~p"/api/v1/status")

      assert revoked.status == 401
      assert revoked.resp_body == unconfigured.resp_body
      # No hint that a key was ever configured.
      refute revoked.resp_body =~ "key"
    end

    test "a duplicated header is rejected rather than tried value by value", %{
      conn: conn,
      key: key
    } do
      conn =
        conn
        |> prepend_req_headers([{"x-api-key", key}, {"x-api-key", "wrong"}])
        |> get(~p"/api/v1/status")

      assert conn.status == 401
    end

    test "an unauthenticated browser-ish Accept still gets the flat 401", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> get(~p"/api/v1/status")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "the optional HTTP Basic edge gate also fronts /api", %{conn: conn, key: key} do
      System.put_env("CINDER_BASIC_AUTH_USER", "edge")
      System.put_env("CINDER_BASIC_AUTH_PASSWORD", "secret")

      on_exit(fn ->
        System.delete_env("CINDER_BASIC_AUTH_USER")
        System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
      end)

      # A valid API key is not enough once the edge gate is on: a proxy config written on
      # "Basic covers everything" must not be silently wrong about /api.
      assert conn |> authed(key) |> get(~p"/api/v1/status") |> Map.fetch!(:status) == 401

      assert conn
             |> authed(key)
             |> put_req_header(
               "authorization",
               Plug.BasicAuth.encode_basic_auth("edge", "secret")
             )
             |> get(~p"/api/v1/status")
             |> json_response(200)
    end

    test "the API scope carries no session or CSRF machinery", %{conn: conn, key: key} do
      conn = conn |> authed(key) |> get(~p"/api/v1/status")

      assert conn.resp_cookies == %{}
      assert response_content_type(conn, :json)
    end
  end
end
