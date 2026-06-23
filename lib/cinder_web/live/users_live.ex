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
     |> assign(users: Accounts.list_users(), creating: false)
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
    user = Accounts.get_user!(String.to_integer(id))

    case Accounts.update_user_quota(user, parse_quota(quota)) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(users: Accounts.list_users()) |> put_flash(:info, "Quota updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Quota must be a non-negative number.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
          <div class="flex items-center gap-3">
            <span class="font-semibold">{u.email}</span>
            <span class="badge badge-sm">{u.role}</span>
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
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
