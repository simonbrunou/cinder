defmodule CinderWeb.IssuesLive do
  @moduledoc """
  Admin queue at `/issues`: open post-delivery problem reports from requesters, each with the
  reporter, title, category, and their free-text detail, plus Resolve/Dismiss actions. Live via
  the `"issues"` PubSub topic. Resolving emails the reporter (see `Cinder.Notifier.Email`).
  """
  use CinderWeb, :live_view

  import CinderWeb.IssueComponents, only: [category_label: 1]
  import CinderWeb.LiveHelpers, only: [find_by_id: 2, relative_time: 1]

  alias Cinder.Issues

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Issues.subscribe()
    {:ok, assign(socket, reports: Issues.list_open())}
  end

  @impl true
  def handle_info({event, _report}, socket)
      when event in [:issue_reported, :issue_resolved, :issue_dismissed] do
    {:noreply, assign(socket, reports: Issues.list_open())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("resolve", %{"id" => id}, socket), do: {:noreply, act(socket, id, :resolve)}
  def handle_event("dismiss", %{"id" => id}, socket), do: {:noreply, act(socket, id, :dismiss)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp act(socket, id, action) do
    admin = socket.assigns.current_scope.user

    result =
      case find_by_id(socket.assigns.reports, id) do
        nil -> nil
        report -> apply(Issues, action, [report, admin])
      end

    case result do
      {:ok, _} ->
        socket
        |> assign(reports: Issues.list_open())
        |> put_flash(:info, done_flash(action))

      nil ->
        socket

      {:error, :not_open} ->
        put_flash(socket, :error, gettext("That report was already handled."))

      _ ->
        put_flash(socket, :error, gettext("Couldn't update that report. Please try again."))
    end
  end

  defp done_flash(:resolve), do: gettext("Report resolved.")
  defp done_flash(:dismiss), do: gettext("Report dismissed.")

  # A season report snapshots only the series name; render its season number alongside.
  defp report_title(%{target_type: "season", season_number: n, title: title}) when not is_nil(n),
    do: gettext("%{title} (Season %{season})", title: title, season: n)

  defp report_title(%{title: title}), do: title

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
    >
      <.header>
        {gettext("Reported issues")}
        <:subtitle>{gettext("Problems requesters flagged on available titles.")}</:subtitle>
      </.header>

      <ul :if={@reports != []} id="issue-reports" class="space-y-3">
        <li :for={r <- @reports} id={"issue-report-#{r.id}"} class="rounded-box bg-base-200/50 p-4">
          <div class="flex flex-wrap items-start gap-x-4 gap-y-2">
            <div class="min-w-0 flex-1">
              <span class="font-semibold break-words">{report_title(r)}</span>
              <span class="block truncate text-sm opacity-70">{r.user.email}</span>
              <span class="mt-1 badge badge-sm badge-outline">{category_label(r.category)}</span>
              <p :if={present?(r.detail)} class="mt-2 max-w-prose text-sm break-words">
                {r.detail}
              </p>
              <p class="mt-1 text-xs text-base-content/60">
                {gettext("Reported %{time_ago}", time_ago: relative_time(r.inserted_at))}
              </p>
            </div>
            <div class="flex shrink-0 gap-2">
              <.button
                variant="primary"
                size="sm"
                phx-click="resolve"
                phx-value-id={r.id}
                phx-disable-with={gettext("Resolving…")}
              >
                {gettext("Resolve")}
              </.button>
              <.button
                variant="ghost"
                size="sm"
                phx-click="dismiss"
                phx-value-id={r.id}
              >
                {gettext("Dismiss")}
              </.button>
            </div>
          </div>
        </li>
      </ul>

      <.empty_state
        :if={@reports == []}
        icon="hero-flag"
        title={gettext("No open issues")}
        message={gettext("Reports requesters file on available titles will appear here.")}
      />
    </Layouts.app>
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
