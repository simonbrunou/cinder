defmodule CinderWeb.UsersLive do
  @moduledoc """
  Admin user list with per-user request quota, mounted at `/users`. Quota is the
  concurrent-pending limit enforced in `Cinder.Requests.create_request/2`
  (blank = unlimited). Admin-gated by the `:admin` live_session.
  """
  use CinderWeb, :live_view

  alias Cinder.Accounts

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, users: Accounts.list_users())}

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
