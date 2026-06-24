defmodule CinderWeb.UsersLive do
  @moduledoc """
  Admin user list with per-user request quota, mounted at `/users`. Quota is the
  concurrent-pending limit enforced in `Cinder.Requests.create_request/2`
  (blank = unlimited). Admin-gated by the `:admin` live_session.
  """
  use CinderWeb, :live_view

  alias Cinder.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       users: Accounts.list_users(),
       creating: false,
       editing_email: nil,
       resetting_pw: nil,
       confirming_delete: nil
     )
     |> assign_create_form()}
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

  def handle_event("validate_create", %{"user" => params}, socket) do
    {:noreply, assign_create_form(socket, params)}
  end

  def handle_event("create", %{"user" => params}, socket) do
    attrs = %{
      email: params["email"],
      password: params["password"],
      password_confirmation: params["password_confirmation"],
      role: role_atom(params["role"])
    }

    case Accounts.create_user(attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(users: Accounts.list_users(), creating: false)
         |> assign_create_form()
         |> put_flash(:info, "User created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: :user))}
    end
  end

  @impl true
  def handle_event("set_quota", %{"_id" => id, "quota" => quota}, socket) do
    with user when not is_nil(user) <- find_user(id),
         {:ok, _} <- Accounts.update_user_quota(user, parse_quota(quota)) do
      {:noreply,
       socket |> assign(users: Accounts.list_users()) |> put_flash(:info, "Quota updated.")}
    else
      nil ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Quota must be a non-negative number.")}
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
       |> assign(users: Accounts.list_users(), editing_email: nil)
       |> put_flash(:info, "Email updated.")}
    else
      nil ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't update email — check the address.")}
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
          {:ok, _} ->
            {:noreply, assign(socket, users: Accounts.list_users())}

          {:error, :last_admin} ->
            {:noreply, put_flash(socket, :error, "Can't demote the last admin.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't change role.")}
        end
    end
  end

  def handle_event("start_reset_pw", %{"id" => id}, socket) do
    {:noreply, assign(socket, resetting_pw: id)}
  end

  def handle_event("cancel_reset_pw", _params, socket) do
    {:noreply, assign(socket, resetting_pw: nil)}
  end

  def handle_event("reset_pw", %{"_id" => id, "user" => params}, socket) do
    actor = socket.assigns.current_scope.user

    attrs = %{
      password: params["password"],
      password_confirmation: params["password_confirmation"]
    }

    with user when not is_nil(user) <- find_user(id),
         {:ok, _} <- Accounts.admin_reset_password(actor, user, attrs) do
      {:noreply,
       socket
       |> assign(resetting_pw: nil)
       |> put_flash(:info, "Password reset — the user's sessions were ended.")}
    else
      nil ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Password must be at least 12 characters.")}
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

      {:ok, _} ->
        {:noreply,
         socket
         |> assign(users: Accounts.list_users(), confirming_delete: nil)
         |> put_flash(:info, "User deleted.")}

      {:error, :self_delete} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, "You can't delete your own account.")}

      {:error, :last_admin} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, "Can't delete the last admin.")}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Look the user up by string-comparing ids (mirroring the sibling admin views),
  # so a forged (non-numeric) phx-value id never hits String.to_integer/get_user!.
  # Sourced from a fresh list rather than the possibly-stale socket snapshot, so a
  # since-deleted row (e.g. a stale second tab) resolves to nil and no-ops instead
  # of raising Ecto.StaleEntryError inside the subsequent mutation.
  defp find_user(id) do
    Enum.find(Accounts.list_users(), &(to_string(&1.id) == id))
  end

  defp role_atom("admin"), do: :admin
  defp role_atom(_), do: :user

  # "" → nil (unlimited); a non-numeric value → -1 so the changeset rejects it.
  defp parse_quota(""), do: nil

  defp parse_quota(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Users<:subtitle>Roles and request quotas.</:subtitle>
      </.header>

      <div class="mb-6">
        <button :if={!@creating} class="btn btn-primary btn-sm" phx-click="start_create">
          New user
        </button>
        <.form
          :if={@creating}
          id="create-user-form"
          for={@create_form}
          phx-change="validate_create"
          phx-submit="create"
          class="card bg-base-200 p-4 space-y-2"
        >
          <.input field={@create_form[:email]} type="email" label="Email" />
          <.input field={@create_form[:password]} type="password" label="Password" />
          <.input
            field={@create_form[:password_confirmation]}
            type="password"
            label="Confirm password"
          />
          <.input
            field={@create_form[:role]}
            type="select"
            label="Role"
            options={[{"User", "user"}, {"Admin", "admin"}]}
          />
          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm" type="submit">Create</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_create">
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <ul class="space-y-3">
        <li :for={u <- @users} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3 flex-wrap">
            <span class="font-semibold">{u.email}</span>
            <button
              id={"role-btn-#{u.id}"}
              class="badge badge-sm"
              phx-click="toggle_role"
              phx-value-id={u.id}
              title="Toggle admin/user"
            >
              {u.role}
            </button>
            <button
              id={"edit-email-btn-#{u.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="start_edit_email"
              phx-value-id={u.id}
            >
              Edit email
            </button>
            <form
              id={"quota-#{u.id}"}
              phx-submit="set_quota"
              class="ml-auto flex items-center gap-2"
            >
              <input type="hidden" name="_id" value={u.id} />
              <label class="text-sm" for={"quota-input-#{u.id}"}>Quota</label>
              <input
                id={"quota-input-#{u.id}"}
                type="number"
                name="quota"
                min="0"
                value={u.request_quota}
                class="input input-sm w-24"
                placeholder="∞"
              />
              <button class="btn btn-sm">Save</button>
            </form>
          </div>
          <.form
            :if={@editing_email == to_string(u.id)}
            id={"edit-email-form-#{u.id}"}
            for={to_form(%{"email" => u.email}, as: :user)}
            phx-submit="save_email"
            class="mt-2 flex items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <input
              type="email"
              name="user[email]"
              value={u.email}
              class="input input-sm input-bordered"
            />
            <button class="btn btn-primary btn-sm" type="submit">Save email</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_edit_email">
              Cancel
            </button>
          </.form>
          <div class="mt-2 flex items-center gap-2 flex-wrap">
            <button
              id={"reset-pw-btn-#{u.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="start_reset_pw"
              phx-value-id={u.id}
            >
              Reset password
            </button>
            <button
              :if={@confirming_delete != to_string(u.id)}
              id={"delete-btn-#{u.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="start_delete"
              phx-value-id={u.id}
            >
              Delete
            </button>
            <span :if={@confirming_delete == to_string(u.id)} class="flex items-center gap-2">
              <span class="text-sm">Delete {u.email}? Requests cascade.</span>
              <button
                id={"confirm-delete-#{u.id}"}
                class="btn btn-error btn-xs"
                phx-click="delete"
                phx-value-id={u.id}
              >
                Confirm delete
              </button>
              <button class="btn btn-ghost btn-xs" phx-click="cancel_delete">Cancel</button>
            </span>
          </div>
          <.form
            :if={@resetting_pw == to_string(u.id)}
            id={"reset-pw-form-#{u.id}"}
            for={to_form(%{}, as: :user)}
            phx-submit="reset_pw"
            class="mt-2 flex items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <input
              type="password"
              name="user[password]"
              placeholder="New password"
              class="input input-sm input-bordered"
            />
            <input
              type="password"
              name="user[password_confirmation]"
              placeholder="Confirm"
              class="input input-sm input-bordered"
            />
            <button class="btn btn-primary btn-sm" type="submit">Set password</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_reset_pw">
              Cancel
            </button>
          </.form>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
