defmodule CinderWeb.UserLive.RegistrationTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.Accounts.IpRateLimiter

  describe "Registration page" do
    test "renders registration page with the first-user bootstrap field", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
      assert html =~ "instance operator is the data controller"
      assert has_element?(lv, "#bootstrap-token")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "registration throttle" do
    test "blocks repeated submissions from the same client", %{conn: conn} do
      previous = Application.get_env(:cinder, :ip_rate_limiting)
      Application.put_env(:cinder, :ip_rate_limiting, true)
      IpRateLimiter.reset()

      on_exit(fn ->
        IpRateLimiter.reset()

        if is_nil(previous),
          do: Application.delete_env(:cinder, :ip_rate_limiting),
          else: Application.put_env(:cinder, :ip_rate_limiting, previous)
      end)

      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # 10 submissions exhaust the per-IP :registration budget (register_attempt runs before
      # register/3, so the outcome of each save doesn't matter — the counter still climbs).
      for _ <- 1..10 do
        render_hook(lv, "save", %{"user" => registration_params(unique_user_email())})
      end

      html = render_hook(lv, "save", %{"user" => registration_params(unique_user_email())})
      assert html =~ "Too many attempts"
    end
  end

  describe "register user" do
    test "fails closed when no first-user bootstrap token is configured", %{conn: conn} do
      with_bootstrap_token(nil, fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/register")
        email = unique_user_email()

        html = render_hook(lv, "save", %{"user" => registration_params(email)})

        refute Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
        assert html =~ "bootstrap token"
      end)
    end

    test "rejects an incorrect first-user bootstrap token", %{conn: conn} do
      with_bootstrap_token("correct-token", fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/register")
        email = unique_user_email()

        html =
          render_hook(lv, "save", %{
            "bootstrap_token" => "wrong-token",
            "user" => registration_params(email)
          })

        refute Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
        assert html =~ "bootstrap token"
      end)
    end

    test "accepts the configured first-user bootstrap token", %{conn: conn} do
      with_bootstrap_token("correct-token", fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/register")
        email = unique_user_email()

        render_hook(lv, "save", %{
          "bootstrap_token" => "correct-token",
          "user" => registration_params(email)
        })

        assert %{role: :admin, active: true} =
                 Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
      end)
    end

    test "later self-registration creates a pending user with the default quota", %{conn: conn} do
      _admin = admin_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#bootstrap-token")
      email = unique_user_email()

      render_hook(lv, "save", %{"user" => registration_params(email)})

      assert %{role: :user, active: false, request_quota: 10} =
               Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
    end

    test "shows the generic confirmation without logging in", %{conn: conn} do
      _admin = admin_fixture()
      conn = init_test_session(conn, %{})
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      password = valid_user_password()

      form =
        form(lv, "#registration_form",
          user: %{email: email, password: password, password_confirmation: password}
        )

      html = render_submit(form)
      assert html =~ "If that address is new"
      assert has_element?(lv, "#registration-confirmation")
      refute get_session(conn, :user_token)
    end

    test "a duplicate email gets the same generic confirmation", %{conn: conn} do
      _admin = admin_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: registration_params(user.email)
        )
        |> render_submit()

      assert result =~ "If that address is new"
      refute result =~ "has already been taken"
      assert has_element?(lv, "#registration-confirmation")
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end

  defp registration_params(email) do
    password = valid_user_password()
    %{"email" => email, "password" => password, "password_confirmation" => password}
  end

  defp with_bootstrap_token(value, fun) do
    previous = Application.get_env(:cinder, :bootstrap_token)

    if is_nil(value),
      do: Application.delete_env(:cinder, :bootstrap_token),
      else: Application.put_env(:cinder, :bootstrap_token, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Application.delete_env(:cinder, :bootstrap_token),
        else: Application.put_env(:cinder, :bootstrap_token, previous)
    end
  end
end
