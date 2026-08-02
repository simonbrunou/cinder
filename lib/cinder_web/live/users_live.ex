defmodule CinderWeb.UsersLive do
  @moduledoc """
  Admin user list with per-user request quota, mounted at `/users`. Quota is the
  concurrent-pending limit enforced in `Cinder.Requests.create_request/2`
  (blank = unlimited). Admin-gated by the `:admin` live_session.

  Also hosts the media-server user import: fetch the configured server's account list
  (`Cinder.Accounts.list_media_server_users/0`), tick the ones to onboard, and create a
  passwordless `:user` account each (`Cinder.Accounts.import_media_server_users/2`).
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Accounts
  alias CinderWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       creating: false,
       editing_email: nil,
       resetting_pw: nil,
       confirming_delete: nil,
       import_users: nil
     )
     |> assign_users()
     |> assign_create_form()}
  end

  defp assign_users(socket) do
    {pending_users, users} = Enum.split_with(Accounts.list_users(), &(not &1.active))
    assign(socket, users: users, pending_users: pending_users)
  end

  defp assign_create_form(socket, params \\ %{"role" => "user"}) do
    assign(socket, :create_form, to_form(params, as: :user))
  end

  def handle_event("start_create", _params, socket) do
    {:noreply, socket |> assign(creating: true) |> assign_create_form()}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, creating: false)}
  end

  def handle_event("validate_create", %{"user" => params}, socket) when is_map(params) do
    {:noreply, assign_create_form(socket, params)}
  end

  def handle_event("create", %{"user" => params}, socket) when is_map(params) do
    actor = socket.assigns.current_scope.user

    attrs = %{
      email: params["email"],
      password: params["password"],
      password_confirmation: params["password_confirmation"],
      role: role_atom(params["role"])
    }

    case Accounts.create_user(actor, attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(creating: false)
         |> assign_users()
         |> assign_create_form()
         |> put_flash(:info, gettext("User created."))}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: :user))}
    end
  end

  def handle_event("load_import", _params, socket) do
    case Accounts.list_media_server_users() do
      {:ok, media_server_users} ->
        {:noreply, assign(socket, import_users: media_server_users)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't read the media server's user list."))}
    end
  end

  def handle_event("cancel_import", _params, socket) do
    {:noreply, assign(socket, import_users: nil)}
  end

  # The checkboxes carry ids only: the entries themselves come from the list this view
  # fetched, so a forged id imports nothing and a forged email is impossible. The payload is
  # a client-supplied query string, so `import[a]=1` arrives as a MAP — keep only the binaries
  # rather than to_string/1 them, which would raise on a map and take the LiveView down.
  # `%{} = params` matters: only a form payload is guaranteed to be a map, so a forged frame
  # carrying a bare list falls through to the catch-all no-op instead of raising BadMapError.
  def handle_event("import", %{} = params, socket) do
    actor = socket.assigns.current_scope.user
    selected = for value <- List.wrap(Map.get(params, "import", [])), is_binary(value), do: value
    entries = Enum.filter(socket.assigns.import_users || [], &(to_string(&1.id) in selected))

    if entries == [] do
      {:noreply, put_flash(socket, :error, gettext("Select at least one account to import."))}
    else
      import_selected(socket, actor, entries)
    end
  end

  def handle_event("approve", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user
    user = find_user(id)

    case user && Accounts.activate_user(actor, user) do
      nil ->
        {:noreply, socket}

      {:ok, _user} ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, gettext("User approved."))}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't approve that account."))}
    end
  end

  def handle_event("deny", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user
    user = find_user(id)

    case user && Accounts.delete_pending_user(actor, user) do
      nil ->
        {:noreply, socket}

      {:ok, _, revoked_tokens} ->
        UserAuth.disconnect_sessions(revoked_tokens)

        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, gettext("Pending account denied."))}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't deny that account."))}
    end
  end

  @impl true
  def handle_event("set_quota", %{"_id" => id, "quota" => quota}, socket) do
    actor = socket.assigns.current_scope.user

    with user when not is_nil(user) <- find_user(id),
         {:ok, _} <- Accounts.update_user_quota(actor, user, parse_quota(quota)) do
      {:noreply,
       socket
       |> assign_users()
       |> put_flash(:info, gettext("Quota updated."))}
    else
      nil ->
        {:noreply, socket}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Quota must be a non-negative number."))}
    end
  end

  def handle_event("start_edit_email", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_email: id)}
  end

  def handle_event("cancel_edit_email", _params, socket) do
    {:noreply, assign(socket, editing_email: nil)}
  end

  def handle_event("save_email", %{"_id" => id, "user" => %{"email" => email}}, socket) do
    actor = socket.assigns.current_scope.user

    with user when not is_nil(user) <- find_user(id),
         {:ok, _} <- Accounts.admin_update_email(actor, user, %{email: email}) do
      {:noreply,
       socket
       |> assign(editing_email: nil)
       |> assign_users()
       |> put_flash(:info, gettext("Email updated."))}
    else
      nil ->
        {:noreply, socket}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't update email. Check the address."))}
    end
  end

  def handle_event("toggle_role", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case find_user(id) do
      nil ->
        {:noreply, socket}

      user ->
        new_role = if user.role == :admin, do: :user, else: :admin

        case Accounts.update_user_role(actor, user, new_role) do
          {:ok, _, revoked_tokens} ->
            UserAuth.disconnect_sessions(revoked_tokens)
            {:noreply, assign_users(socket)}

          {:error, :unauthorized} ->
            unauthorized(socket)

          {:error, :last_admin} ->
            {:noreply, put_flash(socket, :error, gettext("Can't demote the last admin."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't change role."))}
        end
    end
  end

  def handle_event("start_reset_pw", %{"id" => id}, socket) do
    {:noreply, assign(socket, resetting_pw: id)}
  end

  def handle_event("cancel_reset_pw", _params, socket) do
    {:noreply, assign(socket, resetting_pw: nil)}
  end

  def handle_event("reset_pw", %{"_id" => id, "user" => params}, socket) when is_map(params) do
    actor = socket.assigns.current_scope.user

    attrs = %{
      password: params["password"],
      password_confirmation: params["password_confirmation"]
    }

    with user when not is_nil(user) <- find_user(id),
         {:ok, _, revoked_tokens} <- Accounts.admin_reset_password(actor, user, attrs) do
      UserAuth.disconnect_sessions(revoked_tokens)

      {:noreply,
       socket
       |> assign(resetting_pw: nil)
       |> put_flash(:info, gettext("Password reset. The user's sessions were ended."))}
    else
      nil ->
        {:noreply, socket}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, password_error_message(changeset))}
    end
  end

  def handle_event("start_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_delete: id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming_delete: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user
    user = find_user(id)

    case user && Accounts.delete_user(actor, user) do
      nil ->
        {:noreply, socket}

      {:ok, _, revoked_tokens} ->
        UserAuth.disconnect_sessions(revoked_tokens)

        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> assign_users()
         |> put_flash(:info, gettext("User deleted."))}

      {:error, :self_delete} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, gettext("You can't delete your own account."))}

      {:error, :last_admin} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, gettext("Can't delete the last admin."))}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, gettext("Couldn't complete that action."))}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Admin sockets are subscribed to the "requests" topic (nav-badge on_mount); those broadcasts
  # aren't used here — the on_mount hook already re-renders the badge.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Look the user up by string-comparing ids (mirroring the sibling admin views),
  # so a forged (non-numeric) phx-value id never hits String.to_integer/get_user!.
  # Sourced from a fresh list rather than the possibly-stale socket snapshot, so a
  # since-deleted row (e.g. a stale second tab) resolves to nil and no-ops instead
  # of raising Ecto.StaleEntryError inside the subsequent mutation.
  # Surface the actual validation failure — a confirmation mismatch mislabeled as a
  # length problem sends the admin to fix the wrong thing.
  defp password_error_message(%Ecto.Changeset{errors: [{field, error} | _]}) do
    "#{Phoenix.Naming.humanize(field)}: #{translate_error(error)}"
  end

  defp password_error_message(_), do: gettext("Couldn't reset the password.")

  defp unauthorized(socket) do
    {:noreply, put_flash(socket, :error, gettext("You don't have access to that page."))}
  end

  defp find_user(id) do
    find_by_id(Accounts.list_users(), id)
  end

  defp role_atom("admin"), do: :admin
  defp role_atom(_), do: :user

  defp import_selected(socket, actor, entries) do
    case Accounts.import_media_server_users(actor, entries) do
      {:ok, created} ->
        {:noreply,
         socket
         |> assign(import_users: nil)
         |> assign_users()
         |> put_flash(:info, import_message(length(created)))}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't import those accounts."))}
    end
  end

  # Only reachable for a non-empty selection: an empty one is refused before the import runs.
  defp import_message(0), do: gettext("Nothing to import: those accounts already exist.")

  defp import_message(count),
    do: ngettext("Imported %{count} account.", "Imported %{count} accounts.", count)

  # "" → nil (unlimited); a non-numeric value → -1 so the changeset rejects it.
  defp parse_quota(""), do: nil

  defp parse_quota(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end

  # A forged frame can carry a non-binary "quota" (`Integer.parse/1` is itself `when is_binary`,
  # so it would raise here, past the point where a valid `_id` has already resolved). Same -1 as
  # any other unusable value: the changeset rejects it and the admin gets the error flash.
  defp parse_quota(_value), do: -1

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.header>
        {gettext("Users")}
        <:subtitle>{gettext("Roles and request quotas.")}</:subtitle>
      </.header>

      <section
        id="pending-approvals"
        class="rounded-box border border-warning/40 bg-warning/10 p-4 mb-6"
      >
        <h2 class="text-lg font-semibold">{gettext("Pending approval")}</h2>
        <p :if={@pending_users == []} class="mt-2 text-sm text-base-content/60">
          {gettext("No accounts are waiting for approval.")}
        </p>
        <ul :if={@pending_users != []} class="mt-3 space-y-2">
          <li
            :for={user <- @pending_users}
            id={"pending-user-#{user.id}"}
            class="flex flex-wrap items-center gap-2 rounded-box bg-base-100 p-3"
          >
            <span class="min-w-0 flex-1 break-all font-semibold">{user.email}</span>
            <.button
              id={"approve-user-#{user.id}"}
              variant="primary"
              size="sm"
              phx-click="approve"
              phx-value-id={user.id}
              phx-disable-with={gettext("Approving…")}
            >
              {gettext("Approve")}
            </.button>
            <.button
              id={"deny-user-#{user.id}"}
              variant="ghost"
              size="sm"
              class="text-error"
              phx-click="deny"
              phx-value-id={user.id}
              phx-disable-with={gettext("Denying…")}
            >
              {gettext("Deny")}
            </.button>
          </li>
        </ul>
        <p :if={@pending_users != []} class="mt-3 text-sm text-base-content/60">
          {gettext(
            "Seeing a second account for someone who already has one? Their original was never linked to the media server: use Reset password on it below, then have them link their media server account from Account settings."
          )}
        </p>
      </section>

      <section id="import-users" class="mb-6">
        <.button
          :if={is_nil(@import_users)}
          id="load-import-btn"
          variant="neutral"
          size="sm"
          phx-click="load_import"
          phx-disable-with={gettext("Loading…")}
        >
          {gettext("Import from media server")}
        </.button>
        <form
          :if={@import_users}
          id="import-users-form"
          phx-submit="import"
          class="card bg-base-200 p-4 space-y-2"
        >
          <h2 class="font-semibold">{gettext("Import from media server")}</h2>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Imported accounts have no password: they sign in through the media server, or you set one here."
            )}
          </p>
          <p :if={@import_users == []} class="text-sm text-base-content/60">
            {gettext("The media server reported no users.")}
          </p>
          <ul class="space-y-1">
            <li :for={u <- @import_users} id={"import-user-#{u.id}"}>
              <label
                :if={Accounts.importable_media_server_user?(u)}
                class="flex flex-wrap items-center gap-2"
              >
                <input type="checkbox" name="import[]" value={u.id} class="checkbox checkbox-sm" />
                <span class="break-all font-medium">{u.email || u.username || u.id}</span>
                <span :if={u.email && u.username} class="text-sm text-base-content/60">
                  {u.username}
                </span>
                <span :if={is_nil(u.email)} class="text-sm text-base-content/60">
                  {gettext("no email on the media server: a placeholder is generated")}
                </span>
              </label>
              <span
                :if={not Accounts.importable_media_server_user?(u)}
                class="text-sm text-base-content/50"
              >
                {gettext("%{name}: no email on the media server", name: u.username || u.id)}
              </span>
            </li>
          </ul>
          <div class="flex gap-2">
            <.button
              variant="primary"
              size="sm"
              type="submit"
              phx-disable-with={gettext("Importing…")}
            >
              {gettext("Import selected")}
            </.button>
            <.button variant="ghost" size="sm" type="button" phx-click="cancel_import">
              {gettext("Cancel")}
            </.button>
          </div>
        </form>
      </section>

      <div class="mb-6">
        <.button :if={!@creating} variant="primary" size="sm" phx-click="start_create">
          {gettext("New user")}
        </.button>
        <.form
          :if={@creating}
          id="create-user-form"
          for={@create_form}
          phx-change="validate_create"
          phx-submit="create"
          class="card bg-base-200 p-4 space-y-2"
        >
          <.input field={@create_form[:email]} type="email" label={gettext("Email")} />
          <.input
            field={@create_form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="new-password"
          />
          <.input
            field={@create_form[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            autocomplete="new-password"
          />
          <.input
            field={@create_form[:role]}
            type="select"
            label={gettext("Role")}
            options={[{gettext("User"), "user"}, {gettext("Admin"), "admin"}]}
          />
          <div class="flex gap-2">
            <.button
              variant="primary"
              size="sm"
              type="submit"
              phx-disable-with={gettext("Creating…")}
            >
              {gettext("Create")}
            </.button>
            <.button variant="ghost" size="sm" type="button" phx-click="cancel_create">
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>
      </div>

      <ul class="space-y-3">
        <li :for={u <- @users} class="rounded-box bg-base-200/50 p-4">
          <div class="flex items-center gap-3 flex-wrap">
            <span class="min-w-0 break-all font-semibold">{u.email}</span>
            <.button
              id={"role-btn-#{u.id}"}
              variant="neutral"
              size="sm"
              phx-click="toggle_role"
              phx-value-id={u.id}
              phx-disable-with={gettext("…")}
              aria-label={
                gettext("Change role for %{email}, currently %{role}",
                  email: u.email,
                  role: u.role
                )
              }
            >
              <.icon name="hero-arrows-right-left" class="size-3" />{u.role}
            </.button>
            <.button
              id={"edit-email-btn-#{u.id}"}
              variant="ghost"
              size="sm"
              phx-click="start_edit_email"
              phx-value-id={u.id}
            >
              {gettext("Edit email")}
            </.button>
            <form
              id={"quota-#{u.id}"}
              phx-submit="set_quota"
              class="flex w-full items-center gap-2 sm:ml-auto sm:w-auto"
            >
              <input type="hidden" name="_id" value={u.id} />
              <label class="text-sm" for={"quota-input-#{u.id}"}>{gettext("Quota")}</label>
              <input
                id={"quota-input-#{u.id}"}
                type="number"
                name="quota"
                min="0"
                value={u.request_quota}
                class="input input-sm w-24"
                placeholder="∞"
              />
              <.button variant="neutral" size="sm" phx-disable-with={gettext("Saving…")}>{gettext(
                "Save"
              )}</.button>
            </form>
          </div>
          <.form
            :let={f}
            :if={@editing_email == to_string(u.id)}
            id={"edit-email-form-#{u.id}"}
            for={to_form(%{"email" => u.email}, as: :user)}
            phx-submit="save_email"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <.input
              field={f[:email]}
              id={"edit-email-#{u.id}"}
              type="email"
              aria-label={gettext("New email")}
              class="input input-sm input-bordered"
            />
            <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
              {gettext("Save email")}
            </.button>
            <.button variant="ghost" size="sm" type="button" phx-click="cancel_edit_email">
              {gettext("Cancel")}
            </.button>
          </.form>
          <div class="mt-2 flex items-center gap-2 flex-wrap">
            <.button
              id={"reset-pw-btn-#{u.id}"}
              variant="ghost"
              size="sm"
              phx-click="start_reset_pw"
              phx-value-id={u.id}
            >
              {gettext("Reset password")}
            </.button>
            <.button
              :if={@confirming_delete != to_string(u.id)}
              id={"delete-btn-#{u.id}"}
              variant="ghost"
              size="sm"
              class="text-error"
              phx-click="start_delete"
              phx-value-id={u.id}
            >
              {gettext("Delete")}
            </.button>
          </div>
          <.confirm_action
            :if={@confirming_delete == to_string(u.id)}
            id={"confirm-delete-#{u.id}"}
            on_confirm="delete"
            on_cancel="cancel_delete"
            value={u.id}
            confirm_label={gettext("Delete")}
          >
            <:caveat>
              {gettext("Delete %{email}? Their requests are deleted too.", email: u.email)}
            </:caveat>
          </.confirm_action>
          <.form
            :let={f}
            :if={@resetting_pw == to_string(u.id)}
            id={"reset-pw-form-#{u.id}"}
            for={to_form(%{}, as: :user)}
            phx-submit="reset_pw"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <.input
              field={f[:password]}
              id={"reset-pw-#{u.id}"}
              type="password"
              placeholder={gettext("New password")}
              aria-label={gettext("New password")}
              class="input input-sm input-bordered"
            />
            <.input
              field={f[:password_confirmation]}
              id={"reset-pw-confirm-#{u.id}"}
              type="password"
              placeholder={gettext("Confirm")}
              aria-label={gettext("Confirm new password")}
              class="input input-sm input-bordered"
            />
            <.button
              variant="primary"
              size="sm"
              type="submit"
              phx-disable-with={gettext("Resetting…")}
            >
              {gettext("Set password")}
            </.button>
            <.button variant="ghost" size="sm" type="button" phx-click="cancel_reset_pw">
              {gettext("Cancel")}
            </.button>
          </.form>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
