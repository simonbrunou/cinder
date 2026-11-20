defmodule CinderWeb.UserLive.LoginPasskeyTest do
  use CinderWeb.ConnCase, async: true

  import Cinder.AccountsFixtures
  import Phoenix.LiveViewTest

  @fields ~w(id authenticatorData clientDataJSON signature userHandle)

  test "a signed-out visitor gets the passkey form, posting to the passkey route", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log-in")

    form = "#passkey_login_form[action='/users/log-in/passkey'][method=post]"
    assert has_element?(view, "#{form}[phx-hook=PasskeySignIn]")
    assert has_element?(view, "#{form}[data-options-url='/users/log-in/passkey/options']")
    assert has_element?(view, "#{form} input[name=_csrf_token]")
    assert has_element?(view, "#{form} button#passkey_login_button", "Sign in with a passkey")
    assert has_element?(view, "#{form} input[type=checkbox][name='passkey[remember_me]']")

    for field <- @fields do
      assert has_element?(view, "#{form} input[type=hidden][name='passkey[#{field}]']")
    end
  end

  test "a signed-in user re-authenticating gets the passkey button too", %{conn: conn} do
    {:ok, view, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/log-in")

    assert has_element?(view, "#passkey_login_form button#passkey_login_button")
    refute has_element?(view, "#passkey_login_form input[name='passkey[remember_me]']")
  end

  test "a ceremony the browser ended shows a message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log-in")

    render_hook(view, "passkey_failed", %{"reason" => "unsupported"})
    assert has_element?(view, "#flash-error", "This browser cannot use passkeys.")

    render_hook(view, "passkey_failed", %{"reason" => "failed"})
    assert has_element?(view, "#flash-error", "Passkey sign-in failed. Please try again.")
  end
end
