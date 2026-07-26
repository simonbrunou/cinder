defmodule CinderWeb.PendingApprovalLive do
  @moduledoc """
  Waiting room for an account created but not yet admin-approved, mounted at `/pending`.
  Subscribes to the shared `Cinder.Accounts` `"accounts"` topic and, on seeing its OWN
  `{:account_activated, user}` come through, does a full redirect to `/` — not
  `push_navigate` — so the auth pipeline re-reads the now-active user from the DB on the
  next request rather than carrying the stale `current_scope` this process mounted with.
  """
  use CinderWeb, :live_view

  alias Cinder.Accounts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: maybe_subscribe(socket.assigns[:current_scope])

    {:ok, socket}
  end

  @impl true
  def handle_info({:account_activated, %{id: id}}, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: ^id}} -> {:noreply, redirect(socket, to: ~p"/")}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp maybe_subscribe(%{user: %{}}), do: Accounts.subscribe()
  defp maybe_subscribe(_scope), do: :ok

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div id="pending-approval" class="mx-auto max-w-lg text-center">
        <.header>
          {gettext("Pending approval")}
          <:subtitle>
            {gettext("Your account is awaiting administrator approval.")}
          </:subtitle>
        </.header>
        <.link
          id="pending-logout"
          href={~p"/users/log-out"}
          method="delete"
          class="btn btn-primary mt-6"
        >
          {gettext("Log out")}
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
