defmodule CinderWeb.UserLive.Registration do
  use CinderWeb, :live_view

  # Registration has no natural per-account key (no account exists yet) to throttle on, so
  # this LiveView keys Cinder.Accounts.IpRateLimiter's :registration bucket off the client
  # IP — and behind cloudflared that has to be the REAL visitor, not the shared tunnel hop.
  #
  # The `:current_user` live_session in router.ex carries a `:session` MFA
  # (`CinderWeb.Plugs.RemoteIp.session_client_ip/1`) that stashes the cloudflared-resolved
  # `conn.remote_ip` — the endpoint's RemoteIp plug runs before the router — into the session
  # under `"client_ip"`. `mount/3` reads it there, so the bucket keys per visitor even when
  # every visitor shares one transport peer (the tunnel's own hop).
  #
  # peer_data is the FALLBACK for when the session carries no resolved IP: a LiveView
  # otherwise can't see the resolved address. `get_connect_info(socket, :peer_data)` reads the
  # raw TRANSPORT peer, and Phoenix.Socket.Transport's `connect_info` has no key for an
  # arbitrary request header (only :peer_data, :x_headers ("x-" prefix only — doesn't match
  # `cf-connecting-ip`), :trace_context_headers, :uri, :user_agent), so the plug-set session
  # is the only way to thread the real IP in. Off the tunnel (direct/LAN) peer_data is itself
  # the real client IP, so the throttle is precise on either path. The Cloudflare edge Managed
  # Challenge / Rate Limit rule on /users/register (pre-exposure security audit, finding 2)
  # remains the ops-level per-visitor backstop.
  @ip_bucket :registration

  alias Cinder.Accounts
  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="mx-auto max-w-sm">
        <div :if={@submitted} id="registration-confirmation" class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <span :if={@bootstrap_admin}>
            {gettext("Your admin account is ready.")}
            <.link
              navigate={~p"/users/log-in"}
              class="font-semibold text-primary hover:underline focus-visible:underline"
            >
              {gettext("Log in")}
            </.link>
            {gettext("to continue.")}
          </span>
          <span :if={!@bootstrap_admin}>
            {gettext("If that address is new, an administrator will review your request shortly.")}
          </span>
        </div>

        <div :if={!@submitted} class="text-center">
          <.header>
            {gettext("Register for an account")}
            <:subtitle>
              {gettext("Already registered?")}
              <.link
                navigate={~p"/users/log-in"}
                class="font-semibold text-primary hover:underline focus-visible:underline"
              >
                {gettext("Log in")}
              </.link>
              {gettext("to your account now.")}
            </:subtitle>
          </.header>
        </div>

        <.form
          :if={!@submitted}
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
        >
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            autocomplete="new-password"
            required
          />
          <div :if={@bootstrap_required}>
            <label for="bootstrap-token" class="label">
              <span class="label-text">{gettext("Bootstrap token")}</span>
            </label>
            <input
              id="bootstrap-token"
              name="bootstrap_token"
              type="password"
              autocomplete="off"
              aria-describedby="bootstrap-token-help"
              required
              class="input input-bordered w-full"
            />
            <p id="bootstrap-token-help" class="mt-2 text-sm text-base-content/70">
              {gettext(
                "The installer set this one-time password using CINDER_BOOTSTRAP_TOKEN. It is only required to create the first admin account."
              )}
            </p>
          </div>

          <p class="mb-4 text-sm text-base-content/70">
            {gettext(
              "We store your email, hashed password, and request history; the instance operator is the data controller."
            )}
          </p>
          <.button phx-disable-with={gettext("Creating account…")} class="w-full">
            {gettext("Create an account")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: CinderWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, session, socket) do
    changeset = User.registration_changeset(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(
       submitted: false,
       bootstrap_admin: false,
       bootstrap_required: Accounts.count_admins() == 0,
       client_ip: resolve_client_ip(session, peer_ip(socket))
     )
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params} = params, socket) do
    case IpRateLimiter.check_and_register(@ip_bucket, socket.assigns.client_ip) do
      :blocked ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Try again in a minute."))}

      :ok ->
        register(socket, user_params, params["bootstrap_token"])
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      User.registration_changeset(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp register(socket, user_params, bootstrap_token) do
    case Accounts.register_user(user_params, bootstrap_token) do
      {:ok, %User{active: true} = _user} ->
        confirm_registration(socket, bootstrap_admin: true)

      {:ok, _user} ->
        confirm_registration(socket, bootstrap_admin: false)

      {:error, %Ecto.Changeset{} = changeset} ->
        if email_collision?(changeset) do
          confirm_registration(socket, bootstrap_admin: false)
        else
          {:noreply, assign_form(socket, changeset)}
        end

      {:error, :invalid_bootstrap_token} ->
        changeset = User.registration_changeset(%User{}, user_params, validate_unique: false)

        {:noreply,
         socket
         |> put_flash(:error, gettext("Invalid bootstrap token."))
         |> assign_form(changeset)}
    end
  end

  @doc """
  Picks the resolved client IP threaded through the session (see the module note), falling back
  to the raw transport peer when the session carries none. Public only so the fallback branch is
  directly assertable in a test.
  """
  def resolve_client_ip(%{"client_ip" => ip}, _fallback) when is_binary(ip) and ip != "", do: ip
  def resolve_client_ip(_session, fallback), do: fallback

  # The raw connection peer — the tunnel hop behind cloudflared, the real client IP off it.
  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end

  defp confirm_registration(socket, opts) do
    {:noreply,
     assign(socket, submitted: true, bootstrap_admin: Keyword.get(opts, :bootstrap_admin, false))}
  end

  defp email_collision?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:email, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
