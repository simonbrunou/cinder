defmodule CinderWeb.UserLive.Settings do
  use CinderWeb, :live_view

  on_mount {CinderWeb.UserAuth, :require_sudo_mode}

  alias Cinder.Accounts
  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.JellyfinAuth
  alias Cinder.Accounts.Passkeys
  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.UserPasskey
  alias CinderWeb.LiveHelpers
  alias CinderWeb.UserAuth

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
          aria-describedby={!@mail_deliverable? && "email_change_unavailable"}
        />
        <p :if={!@mail_deliverable?} id="email_change_unavailable" class="mb-2 text-sm">
          {email_change_unavailable()}
        </p>
        <.button
          id="change_email_button"
          variant="primary"
          phx-disable-with={gettext("Changing…")}
          disabled={!@mail_deliverable?}
          aria-describedby={!@mail_deliverable? && "email_change_unavailable"}
        >
          {gettext("Change email")}
        </.button>
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
            <%= if @current_scope.user.plex_token do %>
              <form id="plex_watchlist_form" phx-change="toggle_plex_watchlist" class="mt-2">
                <label class="label cursor-pointer justify-start gap-2">
                  <input type="hidden" name="plex_watchlist_sync" value="false" />
                  <input
                    type="checkbox"
                    name="plex_watchlist_sync"
                    value="true"
                    checked={@current_scope.user.plex_watchlist_sync}
                    class="checkbox"
                  />
                  <span class="label-text">
                    {gettext("Request titles I add to my Plex watchlist")}
                  </span>
                </label>
              </form>
            <% else %>
              <p class="mt-2 text-sm opacity-70">
                {gettext("Link your Plex account again to sync your Plex watchlist.")}
              </p>
              <.plex_button
                href={~p"/auth/plex"}
                label={gettext("Relink Plex account")}
                class="mt-2"
              />
            <% end %>

            <.button
              phx-click="unlink_plex"
              variant="neutral"
              class="mt-2"
              data-confirm={
                if @current_scope.user.role == :admin do
                  gettext(
                    "Unlink your Plex account? Plex watchlist sync will stop until you link it again."
                  )
                else
                  gettext(
                    "Unlink your Plex account? You'll need to link it again to sign in with Plex."
                  )
                end
              }
            >
              {gettext("Unlink")}
            </.button>
          <% else %>
            <p class="mt-2">
              <%= if @current_scope.user.role == :admin do %>
                {gettext(
                  "Link your Plex account to use Plex features such as watchlist sync. Administrators sign in with their password, not with Plex."
                )}
              <% else %>
                {gettext("Sign in faster next time by linking your Plex account.")}
              <% end %>
            </p>
            <.plex_button href={~p"/auth/plex"} label={gettext("Link Plex account")} class="mt-2" />
          <% end %>
        </div>
      <% end %>

      <%= if JellyfinAuth.configured?() do %>
        <div class="divider" />

        <div class="text-left">
          <h3 class="text-lg font-semibold">{gettext("Jellyfin account")}</h3>

          <%= if @current_scope.user.jellyfin_user_id do %>
            <p class="mt-2">
              <%= if @current_scope.user.jellyfin_username do %>
                {gettext("Linked as %{username}.", username: @current_scope.user.jellyfin_username)}
              <% else %>
                {gettext("Linked.")}
              <% end %>
            </p>
            <.button
              phx-click="unlink_jellyfin"
              variant="neutral"
              class="mt-2"
              data-confirm={
                gettext(
                  "Unlink your Jellyfin account? You'll need to link it again to sign in with Jellyfin."
                )
              }
            >
              {gettext("Unlink")}
            </.button>
          <% else %>
            <p class="mt-2">
              {gettext("Sign in faster next time by linking your Jellyfin account.")}
            </p>
            <.form
              :let={jf}
              for={@jellyfin_form}
              id="link_jellyfin_form"
              action={~p"/auth/jellyfin"}
              method="post"
              class="mt-2"
            >
              <.input
                field={jf[:username]}
                type="text"
                label={gettext("Jellyfin username")}
                autocomplete="off"
                spellcheck="false"
                required
              />
              <.input
                field={jf[:password]}
                type="password"
                label={gettext("Jellyfin password")}
                autocomplete="off"
                spellcheck="false"
                required
              />
              <.button variant="primary">{gettext("Link Jellyfin account")}</.button>
            </.form>
          <% end %>
        </div>
      <% end %>

      <div class="divider" />

      <section id="passkeys" class="text-left" aria-labelledby="passkeys_heading">
        <h3 id="passkeys_heading" class="text-lg font-semibold">{gettext("Passkeys")}</h3>
        <p class="mt-2">
          {gettext(
            "Sign in with your fingerprint, face or device PIN instead of a password. Your other sign-in methods keep working."
          )}
        </p>

        <ul :if={@passkeys != []} id="passkey_list" class="mt-2 space-y-3">
          <li :for={passkey <- @passkeys} id={"passkey-#{passkey.id}"}>
            <.form
              for={to_form(%{"name" => passkey.name}, as: "passkey_name")}
              id={"rename_passkey_#{passkey.id}"}
              phx-submit="rename_passkey"
              phx-hook="FormState"
              data-form-revision={passkey.name}
              class="flex flex-wrap items-end gap-2"
            >
              <input type="hidden" name="passkey_id" value={passkey.id} />
              <%!-- Each row names its passkey in its accessible names: with several rows, a
              screen reader otherwise hears the same field and buttons on every one. --%>
              <div class="grow">
                <.input
                  id={"passkey_name_#{passkey.id}"}
                  name="name"
                  value={passkey.name}
                  type="text"
                  label={gettext("Passkey name")}
                  aria-label={gettext("Passkey name (%{name})", name: passkey.name)}
                  errors={Map.get(@passkey_errors, passkey.id, [])}
                  maxlength={Cinder.Accounts.UserPasskey.max_name_length()}
                  required
                />
              </div>
              <.button
                variant="neutral"
                phx-disable-with={gettext("Saving…")}
                aria-label={gettext("Rename passkey %{name}", name: passkey.name)}
              >
                {gettext("Rename")}
              </.button>
              <.button
                type="button"
                variant="danger"
                phx-click="delete_passkey"
                phx-value-id={passkey.id}
                aria-label={gettext("Delete passkey %{name}", name: passkey.name)}
                data-confirm={gettext("Delete this passkey? You can no longer sign in with it.")}
              >
                {gettext("Delete")}
              </.button>
            </.form>
            <p class="text-sm opacity-70">
              {gettext("Added %{date}", date: LiveHelpers.format_date_year(passkey.inserted_at))}
              <span :if={passkey.last_used_at}>
                · {gettext("last used %{date}",
                  date: LiveHelpers.format_date_year(passkey.last_used_at)
                )}
              </span>
            </p>
          </li>
        </ul>
        <p :if={@passkeys == []} id="passkey_empty" class="mt-2 text-sm opacity-70">
          {gettext("You have no passkeys yet.")}
        </p>

        <%!-- The PasskeyRegister hook asks for the options, runs the browser's passkey dialog
        and sends the result back; nothing here is submitted as a form. Like FormState, it keeps
        the typed name across a patch until a new passkey bumps the revision. --%>
        <form
          id="add_passkey_form"
          phx-hook="PasskeyRegister"
          data-form-revision={@passkeys_added}
          class="mt-3"
        >
          <.input
            id="new_passkey_name"
            name="name"
            value=""
            type="text"
            label={gettext("Name for the new passkey")}
            placeholder={gettext("For example: Phone")}
            errors={Map.get(@passkey_errors, :new, [])}
            maxlength={Cinder.Accounts.UserPasskey.max_name_length()}
            required
          />
          <.button id="add_passkey_button" variant="primary">
            {gettext("Add a passkey")}
          </.button>
        </form>
      </section>

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
        {:ok, {_user, expired_tokens}} ->
          UserAuth.disconnect_sessions(expired_tokens)
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
      |> assign(:mail_deliverable?, Cinder.Mailer.deliverable?())
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:delete_form, to_form(%{}, as: "delete_account"))
      |> assign(:jellyfin_form, to_form(%{}, as: "jellyfin"))
      |> assign(:trigger_submit, false)
      |> assign(:passkey_errors, %{})
      |> assign(:passkeys_added, 0)
      |> assign_passkeys()

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

  # With no mail transport (`Cinder.Mailer.deliverable?/0`), the confirmation link can never
  # arrive, so the change is refused before any token, rate-limit slot or address lookup. The
  # refusal depends on the install, not on the address, so it tells nothing about which addresses
  # are registered (#1546). The live check, not the mount-time assign, decides: a forged frame
  # skips the disabled button.
  def handle_event("update_email", params, socket) do
    with_sudo_mode(socket, fn ->
      if Cinder.Mailer.deliverable?() do
        update_email(socket, params)
      else
        {:noreply,
         socket
         |> assign(:mail_deliverable?, false)
         |> put_flash(:error, email_change_unavailable())}
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

  # Same low-stakes-preference treatment as toggle_notify_email: no sudo recheck. It only decides
  # whether the user's OWN watchlist is read on their OWN behalf, and every entry it creates still
  # goes through the approval gate and their quota.
  def handle_event("toggle_plex_watchlist", params, socket) do
    user = socket.assigns.current_scope.user
    sync? = Map.get(params, "plex_watchlist_sync") == "true"

    case Accounts.update_user_plex_watchlist_sync(user, %{plex_watchlist_sync: sync?}) do
      {:ok, updated} ->
        {:noreply, assign(socket, current_scope: %{socket.assigns.current_scope | user: updated})}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not update your Plex watchlist preference."))}
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

  def handle_event("unlink_jellyfin", _params, socket) do
    with_sudo_mode(socket, fn ->
      case Accounts.unlink_jellyfin_from_user(socket.assigns.current_scope.user) do
        {:ok, user} ->
          {:noreply,
           socket
           |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
           |> put_flash(:info, gettext("Your Jellyfin account has been unlinked."))}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not unlink your Jellyfin account. Please try again.")
           )}
      end
    end)
  end

  # The PasskeyRegister hook's first step: a sensitive change, so sudo is rechecked here and again
  # on "passkey_register". The reply carries the challenge's handle and the WebAuthn options; the
  # socket keeps neither.
  def handle_event("passkey_registration_options", params, socket) do
    user = socket.assigns.current_scope.user
    # A frame of another shape is forgeable: it reads as no name, which the check below refuses.
    name =
      case params do
        %{"passkey" => %{"name" => name}} when is_binary(name) -> name
        _ -> nil
      end

    cond do
      not Accounts.sudo_mode?(user) ->
        {:reply, %{ok: false}, require_reauth(socket)}

      not (%UserPasskey{} |> UserPasskey.rename_changeset(%{"name" => name})).valid? ->
        {:reply, %{ok: false}, put_passkey_name_error(socket, :new)}

      true ->
        # An accepted name drops the error an earlier name left on the field.
        socket |> clear_passkey_name_error(:new) |> passkey_registration_options(user)
    end
  end

  # Replies `ok` so the hook clears the name field only once the passkey is stored.
  def handle_event("passkey_register", params, socket) do
    user = socket.assigns.current_scope.user

    passkey =
      case params do
        %{"passkey" => %{} = passkey} -> passkey
        _ -> %{}
      end

    if Accounts.sudo_mode?(user) do
      case Passkeys.register(user, passkey["handle"], passkey["response"], passkey["name"]) do
        {:ok, _passkey} ->
          {:reply, %{ok: true},
           socket
           |> assign_passkeys()
           |> update(:passkeys_added, &(&1 + 1))
           |> clear_passkey_name_error(:new)
           |> passkey_flash(:info, gettext("Passkey added."))}

        {:error, %Ecto.Changeset{}} ->
          {:reply, %{ok: false}, put_passkey_name_error(socket, :new)}

        {:error, _reason} ->
          {:reply, %{ok: false}, passkey_flash(socket, :error, passkey_add_failed())}
      end
    else
      {:reply, %{ok: false}, require_reauth(socket)}
    end
  end

  # The hook reports a ceremony that ended in the browser (cancelled, unsupported).
  def handle_event("passkey_failed", params, socket) do
    message =
      case params do
        %{"reason" => "unsupported"} -> gettext("This browser cannot use passkeys.")
        _ -> passkey_add_failed()
      end

    {:noreply, passkey_flash(socket, :error, message)}
  end

  # Renaming changes nothing about who can sign in, so like the toggles above it needs no sudo
  # recheck; the page itself needs sudo at mount.
  def handle_event("rename_passkey", %{"passkey_id" => id, "name" => name}, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, id} <- parse_id(id),
         {:ok, _passkey} <- rename_or_mark(user, id, name) do
      {:noreply,
       socket
       |> assign_passkeys()
       |> clear_passkey_name_error(id)
       |> passkey_flash(:info, gettext("Passkey renamed."))}
    else
      {:invalid_name, id} ->
        {:noreply, put_passkey_name_error(socket, id)}

      _ ->
        {:noreply, socket |> assign_passkeys() |> passkey_flash(:error, passkey_not_found())}
    end
  end

  def handle_event("delete_passkey", %{"id" => id}, socket) do
    with_sudo_mode(socket, fn ->
      with {:ok, id} <- parse_id(id),
           :ok <- Passkeys.delete(socket.assigns.current_scope.user, id) do
        {:noreply,
         socket
         |> assign_passkeys()
         |> clear_passkey_name_error(id)
         |> passkey_flash(:info, gettext("Passkey deleted."))}
      else
        _ -> {:noreply, socket |> assign_passkeys() |> passkey_flash(:error, passkey_not_found())}
      end
    end)
  end

  # Client event frames are forgeable — ignore anything unrecognized rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Only what the page shows: the credential id and the public key stay out of the socket.
  defp assign_passkeys(socket) do
    passkeys =
      socket.assigns.current_scope.user
      |> Passkeys.list()
      |> Enum.map(&Map.take(&1, [:id, :name, :inserted_at, :last_used_at]))

    assign(socket, :passkeys, passkeys)
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error

  defp passkey_name_error do
    gettext("A passkey name needs 1 to %{count} characters.",
      count: UserPasskey.max_name_length()
    )
  end

  defp rename_or_mark(user, id, name) do
    case Passkeys.rename(user, id, %{"name" => name}) do
      {:error, %Ecto.Changeset{}} -> {:invalid_name, id}
      other -> other
    end
  end

  # A passkey action's outcome replaces the one before it, so a success never shows beside the
  # error of an earlier attempt.
  defp passkey_flash(socket, kind, message) do
    socket |> clear_flash(:info) |> clear_flash(:error) |> put_flash(kind, message)
  end

  defp passkey_registration_options(socket, user) do
    if IpRateLimiter.check_and_register(:passkey_options, {:user, user.id}) == :blocked do
      {:reply, %{ok: false},
       passkey_flash(socket, :error, gettext("Too many passkey requests. Try again in a minute."))}
    else
      case Passkeys.registration_options(user, CinderWeb.Passkey.relying_party()) do
        {:ok, %{handle: handle, options: options}} ->
          {:reply, %{ok: true, handle: handle, publicKey: options}, socket}

        {:error, _reason} ->
          {:reply, %{ok: false}, passkey_flash(socket, :error, passkey_add_failed())}
      end
    end
  end

  # The name error shows on the field (`:new` for the add form, a passkey id for its row) and in
  # the flash.
  defp put_passkey_name_error(socket, key) do
    socket
    |> update(:passkey_errors, &Map.put(&1, key, [passkey_name_error()]))
    |> passkey_flash(:error, passkey_name_error())
  end

  defp clear_passkey_name_error(socket, key),
    do: update(socket, :passkey_errors, &Map.delete(&1, key))

  defp passkey_add_failed, do: gettext("The passkey was not added. Please try again.")
  defp passkey_not_found, do: gettext("That passkey no longer exists.")

  defp require_reauth(socket) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp update_email(socket, %{"user" => user_params}) do
    user = socket.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params,
           validate_unique: false,
           validate_changed: true
         ) do
      %{valid?: true} = changeset ->
        request_email_change(socket, user, changeset)

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  defp email_change_unavailable do
    gettext("Email changes need mail set up. Ask an admin to set an SMTP host in Settings.")
  end

  # No uniqueness error at request time (it would enumerate registered addresses to any pending
  # account): a taken address gets the same flash as a free one but no mail — the confirm step
  # (Accounts.update_user_email/2) still rejects it. A failed delivery gets that same flash too,
  # since a different message would tell the user which addresses are registered: `UserNotifier`
  # returns `{:error, _}`, and logs a warning when the mailer raised, exited or threw (#1535), as
  # with a domain the SMTP adapter refuses. Unless `:ip_rate_limiting` is off, a per-user cap
  # bounds the mail relay.
  defp request_email_change(socket, user, changeset) do
    new_email = Ecto.Changeset.get_field(changeset, :email)

    if IpRateLimiter.check_and_register(:user_email, user.id) == :blocked do
      {:noreply,
       put_flash(socket, :error, gettext("Too many email change requests. Try again later."))}
    else
      unless Accounts.email_registered?(new_email, user.id) do
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )
      end

      info =
        gettext(
          "If that address is available, a link to confirm your email change has been sent to it."
        )

      {:noreply, put_flash(socket, :info, info)}
    end
  end

  # Per-event sudo recheck for the sensitive settings actions (email/password change, Plex
  # unlink, adding or deleting a passkey). The mount-time :require_sudo_mode gate only covers the
  # moment the socket connects; a LiveView can stay open past the sudo window, so each sensitive
  # event rechecks freshness against the same shared window (`Accounts.sudo_mode?/1`) and — on
  # expiry — redirects to reauthentication instead of crashing the process on a failed
  # `true = ...` match.
  defp with_sudo_mode(socket, fun) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.user) do
      fun.()
    else
      {:noreply, require_reauth(socket)}
    end
  end
end
