defmodule CinderWeb.PlexAuthRefusalLogTest do
  # async: false: one test turns the Plex media server config off, which every Plex test reads.
  use CinderWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase
  import CinderWeb.SignInRefusalHelpers

  alias Cinder.Accounts.PlexAuthMock
  alias Cinder.Repo

  setup :verify_on_exit!

  @token "secret-token-123"
  @email "secret-person@example.com"
  @username "secret-username"
  @resource_token "secret-resource-token"
  # Two entries shaped like plex.tv's /api/v2/resources answer, neither the household server.
  @resources [
    %{
      "name" => "secret-server-name",
      "clientIdentifier" => "other-server",
      "accessToken" => @resource_token,
      "publicAddress" => "203.0.113.9",
      "connections" => [
        %{"address" => "203.0.113.9", "uri" => "https://203-0-113-9.abc.plex.direct:32400"}
      ]
    },
    %{
      "name" => "secret-player-name",
      "clientIdentifier" => "other-player",
      "accessToken" => @resource_token,
      "publicAddress" => "203.0.113.9",
      "connections" => []
    }
  ]
  @secrets [
    @token,
    @email,
    @username,
    @resource_token,
    "203.0.113.9",
    "plex.direct",
    "secret-server-name",
    "secret-player-name"
  ]

  defp account(id, overrides \\ %{}),
    do: Map.merge(%{id: id, email: @email, username: @username}, overrides)

  defp expect_pin(token \\ @token),
    do: expect(PlexAuthMock, :check_pin, fn 1 -> {:ok, token} end)

  defp expect_account(result), do: expect(PlexAuthMock, :account, fn @token -> result end)

  defp expect_server(result \\ {:ok, "machine-1"}),
    do: expect(PlexAuthMock, :server_machine_id, fn -> result end)

  defp expect_resources(result),
    do: expect(PlexAuthMock, :resource_ids, fn @token -> result end)

  defp login_callback(conn) do
    with_log(fn ->
      conn
      |> init_test_session(%{})
      |> put_session(:plex_pin_id, 1)
      |> get(~p"/auth/plex/callback")
    end)
  end

  defp link_callback(conn, user, login_opts \\ []) do
    with_log(fn ->
      conn
      |> log_in_user(user, login_opts)
      |> put_session(:plex_pin_id, 1)
      |> put_session(:plex_intent, :link)
      |> get(~p"/auth/plex/callback")
    end)
  end

  defp stale, do: [token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)]

  describe "GET /auth/plex" do
    test "step=config when Plex is not configured", %{conn: conn} do
      put_config(Cinder.Library.MediaServer.Plex, url: nil, token: nil)

      {conn, log} = with_log(fn -> get(conn, ~p"/auth/plex") end)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=config reason=not_configured"
      )
    end

    test "step=start_pin when plex.tv refuses the PIN", %{conn: conn} do
      expect(PlexAuthMock, :create_pin, fn -> {:error, {:plex_tv_status, 503}} end)

      {conn, log} = with_log(fn -> get(conn, ~p"/auth/plex") end)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=start_pin reason={plex_tv_status,503}"
      )
    end

    test "step=sudo when a link starts from a session that is not sudo-fresh", %{conn: conn} do
      {conn, log} =
        with_log(fn -> conn |> log_in_user(user_fixture(), stale()) |> get(~p"/auth/plex") end)

      assert redirected_to(conn) == ~p"/users/settings"
      assert_one_refusal(log, "plex_signin refused intent=link step=sudo reason=reauth_required")
    end
  end

  describe "GET /auth/plex/callback, :login" do
    test "step=session when the session holds no PIN", %{conn: conn} do
      {conn, log} =
        with_log(fn -> conn |> init_test_session(%{}) |> get(~p"/auth/plex/callback") end)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert_one_refusal(log, "plex_signin refused intent=login step=session reason=missing_pin")
    end

    test "step=check_pin reason=pending when the PIN is not linked yet", %{conn: conn} do
      expect(PlexAuthMock, :check_pin, fn 1 -> {:error, :pending} end)

      {conn, log} = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not completed"
      assert_one_refusal(log, "plex_signin refused intent=login step=check_pin reason=pending")
    end

    test "step=check_pin with the transport error's reason", %{conn: conn} do
      expect(PlexAuthMock, :check_pin, fn 1 -> {:error, %Req.TransportError{reason: :timeout}} end)

      {_conn, log} = login_callback(conn)

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=check_pin reason=Req.TransportError(timeout)"
      )
    end

    test "step=account when plex.tv refuses the account lookup", %{conn: conn} do
      expect_pin()
      expect_account({:error, {:plex_tv_status, 401}})

      {_conn, log} = login_callback(conn)

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=account reason={plex_tv_status,401}"
      )
    end

    test "step=server_machine_id when the local server's id cannot be read", %{conn: conn} do
      expect_pin()
      expect_account({:ok, account(601)})
      expect_server({:error, :not_configured})

      {_conn, log} = login_callback(conn)

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=server_machine_id reason=not_configured"
      )
    end

    test "step=server_ids when plex.tv's resource list cannot be read", %{conn: conn} do
      expect_pin()
      expect_account({:ok, account(602)})
      expect_server()
      expect_resources({:error, :unexpected_response})

      {_conn, log} = login_callback(conn)

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=server_ids reason=unexpected_response"
      )
    end

    test "step=server_access names the plex.tv id and how many ids the list held", %{conn: conn} do
      expect_pin()
      expect_account({:ok, account(666)})
      expect_server()
      expect_resources({:ok, ["other-1", "other-2"]})

      {conn, log} = login_callback(conn)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=server_access plex_id=666 resources=2 reason=forbidden"
      )
    end

    test "step=account_write reason=admin_password_required for an admin's Plex account", %{
      conn: conn
    } do
      admin_fixture() |> Ecto.Changeset.change(plex_id: 603) |> Repo.update!()
      expect_pin()
      expect_account({:ok, account(603)})
      expect_server()
      expect_resources({:ok, ["machine-1"]})

      {conn, log} = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with your password"

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=account_write reason=admin_password_required"
      )
    end

    test "step=account_write reason=no_email for a Plex account with no email", %{conn: conn} do
      _admin = admin_fixture()
      expect_pin()
      expect_account({:ok, account(604, %{email: nil})})
      expect_server()
      expect_resources({:ok, ["machine-1"]})

      {conn, log} = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no email address"

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=account_write reason=no_email"
      )
    end

    test "step=account_write names only the changeset's fields with errors", %{conn: conn} do
      _admin = admin_fixture()
      _owner = user_fixture(email: @email)
      expect_pin()
      expect_account({:ok, account(605)})
      expect_server()
      expect_resources({:ok, ["machine-1"]})

      {_conn, log} = login_callback(conn)

      assert_one_refusal(
        log,
        "plex_signin refused intent=login step=account_write reason=changeset:email"
      )
    end
  end

  describe "GET /auth/plex/callback, :link" do
    test "step=sudo when the session is not sudo-fresh", %{conn: conn} do
      expect_pin()

      {conn, log} = link_callback(conn, user_fixture(), stale())

      assert redirected_to(conn) == ~p"/users/settings"
      assert_one_refusal(log, "plex_signin refused intent=link step=sudo reason=reauth_required")
    end

    test "step=session reason=logged_out when the linking user is no longer signed in", %{
      conn: conn
    } do
      expect_pin()

      {conn, log} =
        with_log(fn ->
          conn
          |> init_test_session(%{})
          |> put_session(:plex_pin_id, 1)
          |> put_session(:plex_intent, :link)
          |> get(~p"/auth/plex/callback")
        end)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert_one_refusal(log, "plex_signin refused intent=link step=session reason=logged_out")
    end

    test "step=account when plex.tv refuses the account lookup", %{conn: conn} do
      expect_pin()
      expect_account({:error, :unexpected_response})

      {conn, log} = link_callback(conn, user_fixture())

      assert redirected_to(conn) == ~p"/users/settings"

      assert_one_refusal(
        log,
        "plex_signin refused intent=link step=account reason=unexpected_response"
      )
    end

    test "step=server_access names the plex.tv id and how many ids the list held", %{conn: conn} do
      expect_pin()
      expect_account({:ok, account(9002)})
      expect_server()
      expect_resources({:ok, ["some-other-machine"]})

      {_conn, log} = link_callback(conn, user_fixture())

      assert_one_refusal(
        log,
        "plex_signin refused intent=link step=server_access plex_id=9002 resources=1 reason=forbidden"
      )
    end

    test "step=account_write when that Plex account is linked to someone else", %{conn: conn} do
      user_fixture() |> Ecto.Changeset.change(plex_id: 606) |> Repo.update!()
      expect_pin()
      expect_account({:ok, account(606)})
      expect_server()
      expect_resources({:ok, ["machine-1"]})

      {conn, log} = link_callback(conn, user_fixture())

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"

      assert_one_refusal(
        log,
        "plex_signin refused intent=link step=account_write reason=changeset:plex_id"
      )
    end
  end

  describe "no refusal line holds a secret" do
    test "the failing Plex branches with a token, an email, a username and a resources body", %{
      conn: conn
    } do
      _admin = admin_fixture()
      admin_fixture() |> Ecto.Changeset.change(plex_id: 707) |> Repo.update!()
      _owner = user_fixture(email: @email)

      for {label, mocks, request} <- secret_cases() do
        mocks.()
        {_conn, log} = request.(conn)
        refute_secrets(log, "plex_signin", @secrets, label)
      end
    end

    test "PlexAuth.HTTP refusing on the resources plex.tv returns", %{conn: conn} do
      _admin = admin_fixture()
      # A raw row, so PlexAuth.client_identifier/0 finds one and never saves through
      # Cinder.Settings.put/2, which reloads every settings-backed env key.
      Repo.insert!(%Cinder.Settings.Setting{
        key: "plex_client_identifier",
        value: "test-client",
        is_secret: false
      })

      stub_with(PlexAuthMock, Cinder.Accounts.PlexAuth.HTTP)

      for {label, resources_response, expected} <- [
            {"forbidden", {200, @resources},
             "intent=login step=server_access plex_id=4242 resources=2 reason=forbidden"},
            {"5xx", {500, @resources}, "intent=login step=server_ids reason={plex_tv_status,500}"}
          ] do
        expect_pin()
        stub_plex_tv(resources_response)

        {_conn, log} = login_callback(conn)

        refute_secrets(log, "plex_signin", @secrets, label)
        assert_one_refusal(log, "plex_signin refused " <> expected)
      end
    end
  end

  # Each case sets its mocks, then runs one request whose refusal it checks. The token, the email
  # and the username reach every step after check_pin/1, and the resources body sits in the
  # reasons of the resource-list cases.
  defp secret_cases do
    [
      {"account error with a response body",
       fn ->
         expect_pin()

         expect_account(
           {:error,
            %Req.Response{
              status: 401,
              body: %{"authToken" => @token, "email" => @email, "username" => @username}
            }}
         )
       end, &login_callback/1},
      {"account error with an exception message",
       fn ->
         expect_pin()
         expect_account({:error, RuntimeError.exception("#{@token} #{@email} #{@username}")})
       end, &login_callback/1},
      {"server_machine_id error holding the body",
       fn ->
         expect_pin()
         expect_account({:ok, account(701)})
         expect_server({:error, {:unexpected_body, @resources}})
       end, &login_callback/1},
      {"server_ids error with a response body",
       fn ->
         expect_pin()
         expect_account({:ok, account(702)})
         expect_server()
         expect_resources({:error, %Req.Response{status: 500, body: @resources}})
       end, &login_callback/1},
      {"server_ids error holding the body",
       fn ->
         expect_pin()
         expect_account({:ok, account(703)})
         expect_server()
         expect_resources({:error, {:unexpected_body, @resources}})
       end, &login_callback/1},
      {"server_access",
       fn ->
         expect_pin()
         expect_account({:ok, account(704)})
         expect_server()
         expect_resources({:ok, ["other-server", "other-player"]})
       end, &login_callback/1},
      {"account_write admin_password_required",
       fn ->
         expect_pin()
         expect_account({:ok, account(707)})
         expect_server()
         expect_resources({:ok, ["machine-1"]})
       end, &login_callback/1},
      {"account_write no_email",
       fn ->
         expect_pin()
         expect_account({:ok, account(705, %{email: nil})})
         expect_server()
         expect_resources({:ok, ["machine-1"]})
       end, &login_callback/1},
      {"account_write changeset",
       fn ->
         expect_pin()
         expect_account({:ok, account(706)})
         expect_server()
         expect_resources({:ok, ["machine-1"]})
       end, &login_callback/1},
      {"link server_access",
       fn ->
         expect_pin()
         expect_account({:ok, account(708)})
         expect_server()
         expect_resources({:ok, ["other-server"]})
       end, &link_callback(&1, user_fixture())},
      {"link account_write changeset",
       fn ->
         expect_pin()
         expect_account({:ok, account(707)})
         expect_server()
         expect_resources({:ok, ["machine-1"]})
       end, &link_callback(&1, user_fixture())},
      {"link logged_out", fn -> expect_pin() end,
       fn conn ->
         with_log(fn ->
           conn
           |> init_test_session(%{})
           |> put_session(:plex_pin_id, 1)
           |> put_session(:plex_intent, :link)
           |> get(~p"/auth/plex/callback")
         end)
       end}
    ]
  end

  # plex.tv's account and resources endpoints and the local server's /identity, through the
  # Req.Test plug config/test.exs gives PlexAuth.HTTP.
  defp stub_plex_tv({resources_status, resources_body}) do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      case conn.request_path do
        "/api/v2/user" ->
          Req.Test.json(conn, %{"id" => 4242, "email" => @email, "username" => @username})

        "/api/v2/resources" ->
          conn |> Plug.Conn.put_status(resources_status) |> Req.Test.json(resources_body)

        "/identity" ->
          Req.Test.json(conn, %{"MediaContainer" => %{"machineIdentifier" => "machine-1"}})
      end
    end)
  end
end
