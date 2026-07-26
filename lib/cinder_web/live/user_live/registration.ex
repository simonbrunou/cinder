defmodule CinderWeb.UserLive.Registration do
  use CinderWeb, :live_view

  # Registration has no natural per-account key (no account exists yet) to throttle on, so
  # this LiveView keys Cinder.Accounts.IpRateLimiter's :registration bucket off the raw
  # connection peer (`get_connect_info(socket, :peer_data)`), the one signal a LiveView can
  # read without a router change (see file scope note below).
  #
  # ponytail: this is the raw TRANSPORT peer, not a cloudflared-resolved client IP — Plug's
  # `get_peer_data/1` always reads the adapter/transport layer directly, never
  # `conn.remote_ip`, and Phoenix.Socket.Transport's `connect_info` has no key for an
  # arbitrary request header (only :peer_data, :x_headers ("x-" prefix only — doesn't match
  # `cf-connecting-ip`), :trace_context_headers, :uri, :user_agent). Threading the real
  # per-visitor IP in here would need a custom `:session` function on this LiveView's route
  # in router.ex, which is out of scope for this fix (owned by a concurrent change).
  #
  # Net effect behind cloudflared: every visitor's peer is the same tunnel hop, so this
  # bucket collapses from "10/min per visitor" to "10/min total" — still a real cap on
  # worst-case bcrypt CPU cost (this fix's actual goal), just not per-visitor fairness. The
  # Cloudflare edge Managed Challenge / Rate Limit rule on /users/register (pre-exposure
  # security audit, finding 2, ops-level) is the per-visitor backstop. Off the tunnel
  # (direct/LAN access), peer_data IS the real client IP and this throttle is fully precise.
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
          <span>
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
              required
              class="input input-bordered w-full"
            />
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

  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(
       submitted: false,
       bootstrap_required: Accounts.count_admins() == 0,
       client_ip: client_ip(socket)
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
      {:ok, _user} ->
        confirm_registration(socket)

      {:error, %Ecto.Changeset{} = changeset} ->
        if email_collision?(changeset) do
          confirm_registration(socket)
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

  # See the module-level ponytail note: this is the raw connection peer, degrading to one
  # shared value per bucket behind a reverse proxy/tunnel that doesn't terminate at us.
  defp client_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end

  defp confirm_registration(socket), do: {:noreply, assign(socket, submitted: true)}

  defp email_collision?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:email, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
