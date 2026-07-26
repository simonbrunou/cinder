defmodule CinderWeb.UserLive.Settings do
  use CinderWeb, :live_view

  on_mount {CinderWeb.UserAuth, :require_sudo_mode}

  alias Cinder.Accounts
  alias Cinder.Accounts.PlexAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="text-center">
        <.header>
          {gettext("Account settings")}
          <:subtitle>{gettext("Manage your account email address and password settings")}</:subtitle>
        </.header>
      </div>

      <.form
        for={@locale_form}
        id="locale_form"
        phx-submit="update_locale"
        phx-change="validate_locale"
      >
        <.input
          field={@locale_form[:locale]}
          type="select"
          label={gettext("Language")}
          prompt={gettext("Use session or browser language")}
          options={[
            {gettext("English"), "en"},
            {gettext("French"), "fr"}
          ]}
        />
        <.button variant="primary" phx-disable-with={gettext("Saving…")}>
          {gettext("Save language")}
        </.button>
      </.form>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with={gettext("Changing…")}>{gettext("Change email")}</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={gettext("New password")}
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label={gettext("Confirm new password")}
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with={gettext("Saving…")}>
          {gettext("Save password")}
        </.button>
      </.form>

      <div class="divider" />

      <div class="text-left">
        <form id="notify_email_form" phx-change="toggle_notify_email">
          <label class="label cursor-pointer justify-start gap-2">
            <input type="hidden" name="notify_email" value="false" />
            <input
              type="checkbox"
              name="notify_email"
              value="true"
              checked={@current_scope.user.notify_email}
              class="checkbox"
            />
            <span class="label-text">
              {gettext("Email me when a request is approved or ready to watch")}
            </span>
          </label>
        </form>
      </div>

      <%= if PlexAuth.configured?() do %>
        <div class="divider" />

        <div class="text-left">
          <h3 class="text-lg font-semibold">{gettext("Plex account")}</h3>

          <%= if @current_scope.user.plex_id do %>
            <p class="mt-2">
              <%= if @current_scope.user.plex_username do %>
                {gettext("Linked as %{username}.", username: @current_scope.user.plex_username)}
              <% else %>
                {gettext("Linked.")}
              <% end %>
            </p>
            <.button phx-click="unlink_plex" variant="neutral" class="mt-2">
              {gettext("Unlink")}
            </.button>
          <% else %>
            <p class="mt-2">
              {gettext("Sign in faster next time by linking your Plex account.")}
            </p>
            <.plex_button href={~p"/auth/plex"} label={gettext("Link Plex account")} class="mt-2" />
          <% end %>
        </div>
      <% end %>

      <div class="divider" />

      <div class="text-left">
        <h3 class="text-lg font-semibold">{gettext("Your data")}</h3>
        <p class="mt-2">
          {gettext("Download a copy of your account and request history as a JSON file.")}
        </p>
        <.button href={~p"/users/export"} download variant="neutral" class="mt-2">
          {gettext("Download my data")}
        </.button>
      </div>

      <div class="divider" />

      <div class="text-left">
        <h3 class="text-lg font-semibold text-error">{gettext("Danger zone")}</h3>
        <p class="mt-2">
          {gettext("Permanently delete your account and all of your requests. This cannot be undone.")}
        </p>
        <.form
          for={@delete_form}
          id="delete_account_form"
          action={~p"/users/delete-account"}
          method="post"
          class="mt-2"
        >
          <.input
            field={@delete_form[:password]}
            type="password"
            label={gettext("Confirm your current password")}
            autocomplete="current-password"
            spellcheck="false"
            required
          />
          <.button
            variant="danger"
            data-confirm={gettext("Permanently delete your account? This cannot be undone.")}
          >
            {gettext("Delete my account")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    locale_changeset = Accounts.change_user_locale(user)
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:locale_form, to_form(locale_changeset))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:delete_form, to_form(%{}, as: "delete_account"))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_locale", %{"user" => user_params}, socket) do
    locale_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_locale(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, locale_form: locale_form)}
  end

  def handle_event("update_locale", %{"user" => user_params}, socket) do
    case Accounts.update_user_locale(socket.assigns.current_scope.user, user_params) do
      {:ok, user} ->
        locale = user.locale || socket.assigns.locale
        Gettext.put_locale(CinderWeb.Gettext, locale)

        {:noreply,
         socket
         |> assign(
           current_scope: %{socket.assigns.current_scope | user: user},
           locale: locale,
           locale_form: to_form(Accounts.change_user_locale(user))
         )
         |> put_flash(:info, gettext("Language updated."))
         |> redirect(to: ~p"/users/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, locale_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    with_sudo_mode(socket, fn ->
      %{"user" => user_params} = params
      user = socket.assigns.current_scope.user

      case Accounts.change_user_email(user, user_params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_user_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            user.email,
            &url(~p"/users/settings/confirm-email/#{&1}")
          )

          info = gettext("A link to confirm your email change has been sent to the new address.")
          {:noreply, socket |> put_flash(:info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    end)
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    with_sudo_mode(socket, fn ->
      %{"user" => user_params} = params
      user = socket.assigns.current_scope.user

      case Accounts.change_user_password(user, user_params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
      end
    end)
  end

  # Low-stakes preference, unlike email/password/Plex-link — no sudo recheck, matching
  # SettingsLive's own toggle_auto_approve.
  def handle_event("toggle_notify_email", params, socket) do
    user = socket.assigns.current_scope.user
    notify_email = Map.get(params, "notify_email") == "true"

    case Accounts.update_user_notify_email(user, %{notify_email: notify_email}) do
      {:ok, updated} ->
        {:noreply, assign(socket, current_scope: %{socket.assigns.current_scope | user: updated})}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not update your notification preference.")
         )}
    end
  end

  def handle_event("unlink_plex", _params, socket) do
    with_sudo_mode(socket, fn ->
      case Accounts.unlink_plex_from_user(socket.assigns.current_scope.user) do
        {:ok, user} ->
          {:noreply,
           socket
           |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
           |> put_flash(:info, gettext("Your Plex account has been unlinked."))}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not unlink your Plex account. Please try again.")
           )}
      end
    end)
  end

  # Client event frames are forgeable — ignore anything unrecognized rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Per-event sudo recheck for the sensitive settings actions (email/password change, Plex
  # unlink). The mount-time :require_sudo_mode gate only covers the moment the socket connects;
  # a LiveView can stay open past the sudo window, so each sensitive event rechecks freshness
  # against the same shared window (`Accounts.sudo_mode?/1`) and — on expiry — redirects to
  # reauthentication instead of crashing the process on a failed `true = ...` match.
  defp with_sudo_mode(socket, fun) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.user) do
      fun.()
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You must re-authenticate to access this page."))
       |> redirect(to: ~p"/users/log-in")}
    end
  end
end
