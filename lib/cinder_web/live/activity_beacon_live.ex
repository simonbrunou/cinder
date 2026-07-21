defmodule CinderWeb.ActivityBeaconLive do
  @moduledoc """
  The always-mounted pipeline beacon: a floating pill (live "N active · N need you" counts,
  links to `/activity`) plus transient toasts when a movie goes available, a movie parks, or a
  download needs attention. Rendered once in `root.html.heex` as a sticky nested LiveView
  (admin-gated there), so it survives live navigation and shows on every page.

  Its own process owns its own `"movies"`/`"series"` subscriptions — the page LiveViews
  subscribe independently, so there is no double delivery. Toasts fire only on a *change* into a
  noteworthy state (diffed against the last-seen status per id), so a metadata re-broadcast on an
  already-available movie doesn't re-toast.

  ponytail: re-derives grab/held counts by re-querying on each `series` broadcast — the coarse
  `{:series_updated, _}` carries no grab. Household scale (a handful of rows); if grab churn ever
  gets heavy, carry the changed grab in the broadcast instead.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog

  @toast_ttl :timer.seconds(6)

  # movie_badge_status/1 and grab_state/1 values, split into "in flight" vs "needs a human".
  @active_movie [:requested, :searching, :downloading, :downloaded, :upgrading]
  @attention_movie [:no_match, :search_failed, :import_failed, :verification_hold, :anime_hold]
  @active_grab [:downloading, :downloaded]
  @attention_grab [:needs_mapping, :verification_blocked]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     socket
     |> assign(
       movies: movie_map(),
       grabs: grab_map(),
       held: held_count(),
       toasts: [],
       next_toast: 0
     )
     |> recount()}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    status = movie_badge_status(movie)
    changed? = status != Map.get(socket.assigns.movies, movie.id)

    {:noreply,
     socket
     |> then(&if(changed?, do: maybe_toast_movie(&1, movie, status), else: &1))
     |> update(:movies, &Map.put(&1, movie.id, status))
     |> recount()}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply,
     socket
     |> update(:movies, &Map.put(&1, movie.id, movie_badge_status(movie)))
     |> recount()}
  end

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, socket |> update(:movies, &Map.delete(&1, id)) |> recount()}

  def handle_info({msg, _id}, socket) when msg in [:series_updated, :series_deleted] do
    grabs = grab_map()

    {:noreply,
     socket
     |> toast_new_grab_attention(grabs)
     |> assign(grabs: grabs, held: held_count())
     |> recount()}
  end

  def handle_info({:clear_toast, ref}, socket),
    do: {:noreply, update(socket, :toasts, &Enum.reject(&1, fn t -> t.id == ref end))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp movie_map, do: Map.new(Catalog.list_movies(), &{&1.id, movie_badge_status(&1)})
  defp grab_map, do: Map.new(Catalog.list_grabs(), &{&1.id, grab_state(&1)})
  defp held_count, do: length(Catalog.list_anime_held_series())

  defp recount(socket) do
    %{movies: movies, grabs: grabs, held: held} = socket.assigns

    active = count_in(movies, @active_movie) + count_in(grabs, @active_grab)
    attention = count_in(movies, @attention_movie) + count_in(grabs, @attention_grab) + held

    assign(socket, active: active, attention: attention)
  end

  defp count_in(map, states), do: Enum.count(map, fn {_id, s} -> s in states end)

  defp maybe_toast_movie(socket, movie, :available),
    do: toast(socket, :success, gettext("“%{title}” is now available.", title: movie.title))

  defp maybe_toast_movie(socket, movie, status) when status in @attention_movie,
    do: toast(socket, :warning, gettext("“%{title}” needs attention.", title: movie.title))

  defp maybe_toast_movie(socket, _movie, _status), do: socket

  # A grab that just entered a hold state it wasn't in before — one toast per newly-held grab.
  defp toast_new_grab_attention(socket, grabs) do
    old = socket.assigns.grabs

    grabs
    |> Enum.filter(fn {id, s} ->
      s in @attention_grab and Map.get(old, id) not in @attention_grab
    end)
    |> Enum.reduce(socket, fn _grab, acc ->
      toast(acc, :warning, gettext("A download needs attention."))
    end)
  end

  defp toast(socket, kind, text) do
    id = socket.assigns.next_toast
    Process.send_after(self(), {:clear_toast, id}, @toast_ttl)

    socket
    |> update(:toasts, &(&1 ++ [%{id: id, kind: kind, text: text}]))
    |> assign(next_toast: id + 1)
  end

  defp alert_class(:success), do: "alert-success"
  defp alert_class(:warning), do: "alert-warning"
  defp alert_class(:error), do: "alert-error"
  defp alert_class(_), do: "alert-info"

  defp pill_label(active, attention) do
    parts =
      [
        active > 0 && gettext("%{count} active", count: active),
        attention > 0 && gettext("%{count} need attention", count: attention)
      ]
      |> Enum.filter(& &1)

    gettext("Pipeline: %{summary}", summary: Enum.join(parts, ", "))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="activity-beacon">
      <.link
        :if={@active > 0 or @attention > 0}
        navigate={~p"/activity"}
        aria-label={pill_label(@active, @attention)}
        class="fixed bottom-4 right-4 z-40 flex items-center gap-2 rounded-full bg-base-300 px-4 py-2 text-sm font-medium shadow-lg ring-1 ring-base-content/10 transition hover:bg-base-200"
      >
        <span :if={@active > 0} class="flex items-center gap-1.5">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          {gettext("%{count} active", count: @active)}
        </span>
        <span
          :if={@attention > 0}
          class="badge badge-warning badge-sm gap-1"
          aria-hidden="true"
        >
          <.icon name="hero-exclamation-triangle-mini" class="size-3" />{@attention}
        </span>
      </.link>

      <div
        id="activity-beacon-toasts"
        class="toast toast-top toast-end z-50"
        role="status"
        aria-live="polite"
      >
        <div
          :for={t <- @toasts}
          id={"beacon-toast-#{t.id}"}
          class={["alert py-2 text-sm shadow-lg", alert_class(t.kind)]}
        >
          <span>{t.text}</span>
        </div>
      </div>
    </div>
    """
  end
end
