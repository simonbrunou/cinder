defmodule CinderWeb.Router do
  use CinderWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CinderWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Optional HTTP Basic auth in front of the app — defense-in-depth behind the
  # Caddy + VPN edge, so a write action (the /status retry) doesn't depend solely
  # on the network. Credentials are read from env at runtime; with either unset the
  # plug is a no-op, so dev/test/local are unaffected until both are set.
  pipeline :admin_auth do
    plug :basic_auth
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
    pipe_through [:browser, :admin_auth]

    live "/", WatchlistLive
    live "/status", StatusLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", CinderWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cinder, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CinderWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
