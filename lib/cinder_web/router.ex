defmodule CinderWeb.Router do
  use CinderWeb, :router

  import CinderWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CinderWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    # Optional HTTP Basic auth — defense-in-depth behind the Caddy + VPN edge.
    # Credentials are read from env at runtime; with either unset the plug is a
    # no-op, so dev/test/local are unaffected until both are set.
    plug :basic_auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  defp basic_auth(conn, _opts) do
    user = present(System.get_env("CINDER_BASIC_AUTH_USER"))
    pass = present(System.get_env("CINDER_BASIC_AUTH_PASSWORD"))

    case {user, pass} do
      {user, pass} when is_binary(user) and is_binary(pass) ->
        Plug.BasicAuth.basic_auth(conn, username: user, password: pass)

      {nil, nil} ->
        conn

      # Exactly one credential present (or a typo) — fail loud and closed rather than
      # silently serving open, which would hide the misconfig from an operator who
      # believes they enabled auth.
      _ ->
        raise "set both CINDER_BASIC_AUTH_USER and CINDER_BASIC_AUTH_PASSWORD, or neither"
    end
  end

  # A blank/whitespace env var counts as unset, so empty credentials can never
  # *enable* auth (is_binary("") is true — a naive guard would accept empty creds).
  defp present(nil), do: nil

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  scope "/", CinderWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{CinderWeb.UserAuth, :require_authenticated}] do
      live "/", WatchlistLive
    end

    live_session :admin,
      on_mount: [
        {CinderWeb.UserAuth, :require_authenticated},
        {CinderWeb.UserAuth, :require_admin}
      ] do
      live "/status", StatusLive
      live "/settings", SettingsLive
      # live "/requests", RequestsLive   # enabled in Task 2.4
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", CinderWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development.
  # Gated to authenticated admins only — /dev tooling must not be public.
  if Application.compile_env(:cinder, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :require_authenticated_user, :require_admin]

      live_dashboard "/dashboard", metrics: CinderWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", CinderWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{CinderWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", CinderWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{CinderWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
