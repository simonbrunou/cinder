defmodule CinderWeb.UserSessionControllerTest do
  use CinderWeb.ConnCase

  import Cinder.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "records all concurrent failures atomically" do
      limiter = Cinder.Accounts.LoginRateLimiter
      ip = "203.0.113.9"
      email = "RACE@example.com"
      limiter.reset()
      parent = self()

      runner =
        Task.async(fn ->
          1..100
          |> Task.async_stream(
            fn _ ->
              send(parent, {:ready, self()})
              receive do: (:go -> limiter.register_failure(ip, email))
            end,
            max_concurrency: 100,
            ordered: false
          )
          |> Stream.run()
        end)

      tasks = for _ <- 1..100, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(tasks, &send(&1, :go))
      Task.await(runner)

      assert [{{^ip, "race@example.com"}, 100, _started}] =
               :ets.lookup(:cinder_login_attempts, {ip, "race@example.com"})

      assert limiter.blocked?(ip, email)
    end

    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_cinder_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "sets Secure on the production-configured remember-me cookie", %{
      conn: conn,
      user: user
    } do
      previous = Application.get_env(:cinder, :secure_cookies)
      Application.put_env(:cinder, :secure_cookies, true)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:cinder, :secure_cookies),
          else: Application.put_env(:cinder, :secure_cookies, previous)
      end)

      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert Enum.any?(get_resp_header(conn, "set-cookie"), fn header ->
               header =~ "_cinder_web_user_remember_me=" and header =~ "; secure"
             end)
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "locks the {ip, email} pair after repeated failures — even with the right password", %{
      conn: conn,
      user: user
    } do
      user = set_password(user)

      for _ <- 1..10 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong_password"}
        })
      end

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      # Same generic response as bad credentials — the limiter is not a lockout oracle.
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a successful login clears the pair's failure budget", %{conn: conn, user: user} do
      user = set_password(user)

      for _ <- 1..9 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong_password"}
        })
      end

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end

    test "an authenticated password change is never blocked by a locked login pair", %{
      conn: conn,
      user: user
    } do
      user = set_password(user)

      # Lock the {ip, email} pair (e.g. an attacker hammering the login form).
      for _ <- 1..10 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong_password"}
        })
      end

      # update_password expires every session token then re-logs-in through create/3 —
      # a blocked pair there would lock the user out of the password they JUST set.
      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => "brand new pass phrase!",
            "password_confirmation" => "brand new pass phrase!"
          }
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/settings"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
