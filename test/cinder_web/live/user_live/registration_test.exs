defmodule CinderWeb.UserLive.RegistrationTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  describe "Registration page" do
    test "renders registration page with the first-user bootstrap field", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
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

        assert %{role: :admin} = Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
      end)
    end

    test "later self-registration stays open and creates a normal user", %{conn: conn} do
      _existing = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#bootstrap-token")
      email = unique_user_email()

      render_hook(lv, "save", %{"user" => registration_params(email)})

      assert %{role: :user} = Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
    end

    test "creates account and logs in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      password = valid_user_password()

      form =
        form(lv, "#registration_form",
          bootstrap_token: "test-bootstrap-token",
          user: %{email: email, password: password, password_confirmation: password}
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email, "password" => valid_user_password()}
        )
        |> render_submit()

      assert result =~ "has already been taken"
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
