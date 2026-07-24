defmodule CinderWeb.PendingApprovalLive do
  use CinderWeb, :live_view

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
