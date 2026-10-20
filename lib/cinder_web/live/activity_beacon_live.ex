defmodule CinderWeb.ActivityBeaconLive do
  @moduledoc """
  The always-mounted pipeline beacon: a floating pill (live "N active, N need attention" counts,
  links to `/activity`) plus transient toasts when a movie goes available, a movie or series
  starts needing attention, or a download needs attention. Rendered once in `root.html.heex` as a
  sticky nested LiveView (admin-gated there), so it survives live navigation and shows on every
  page.

  Its own process owns its own `"movies"`/`"series"` subscriptions — the page LiveViews
  subscribe independently, so there is no double delivery. Toasts fire only on a *change* into a
  noteworthy state (diffed against the last-seen status per id), so a metadata re-broadcast on an
  already-available movie doesn't re-toast. Both counts are phases of `Catalog.Attention.classify/1`
  per item: "active" counts `:active`, "need attention" counts `:attention`, the same rule as the
  Activity nav badge (`Catalog.Attention.attention_count/0`), so the two never disagree on one page.

  ponytail: re-derives grab and held-series counts by re-querying on each `series` broadcast — the
  coarse `{:series_updated, _}` carries no grab or series. Household scale (a handful of rows); if
  grab churn ever gets heavy, carry the changed grab in the broadcast instead.
  """
  use CinderWeb, :live_view

  # Mounted via `live_render` in root.html.heex, outside every router `live_session` — the
  # on_mount hooks those attach (including locale) don't run here on their own, so wire it
  # directly. The session it's rendered with already carries "locale" (the same conn session
  # every live_session reads it from).
  on_mount {CinderWeb.UserAuth, :require_authenticated}
  on_mount {CinderWeb.UserAuth, :require_active}
  on_mount {CinderWeb.UserAuth, :require_admin}
  on_mount CinderWeb.Locale

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog
  alias Cinder.Catalog.Attention

  @toast_ttl :timer.seconds(6)

  # Each id maps to `{badge, phase}` from `Attention.classify/1`. A series is tracked only while it
  # is on an anime hold: that is the only state it classifies on.

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
       series: series_map(Catalog.list_anime_held_series()),
       toasts: [],
       next_toast: 0
     )
     |> recount()}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    entry = movie_entry(movie)
    changed? = entry != Map.get(socket.assigns.movies, movie.id)

    {:noreply,
     socket
     |> then(&if(changed?, do: maybe_toast_movie(&1, movie, entry), else: &1))
     |> update(:movies, &Map.put(&1, movie.id, entry))
     |> recount()}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply,
     socket
     |> update(:movies, &Map.put(&1, movie.id, movie_entry(movie)))
     |> recount()}
  end

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, socket |> update(:movies, &Map.delete(&1, id)) |> recount()}

  def handle_info({msg, _id}, socket) when msg in [:series_updated, :series_deleted] do
    grabs = grab_map()
    held = Catalog.list_anime_held_series()
    series = series_map(held)

    {:noreply,
     socket
     |> toast_new_grab_attention(grabs)
     |> toast_new_series_attention(held, series)
     |> assign(grabs: grabs, series: series)
     |> recount()}
  end

  def handle_info({:clear_toast, ref}, socket),
    do: {:noreply, update(socket, :toasts, &Enum.reject(&1, fn t -> t.id == ref end))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp movie_map, do: Map.new(Catalog.list_movies(), &{&1.id, movie_entry(&1)})
  defp grab_map, do: Map.new(Catalog.list_grabs(), &{&1.id, grab_entry(&1)})
  defp series_map(held), do: Map.new(held, &{&1.id, entry(Attention.classify(&1))})

  defp movie_entry(movie), do: entry(Attention.classify(movie))
  defp grab_entry(grab), do: entry(Attention.classify(grab))
  defp entry(%Attention{badge: badge, phase: phase}), do: {badge, phase}

  defp recount(socket) do
    maps = [socket.assigns.movies, socket.assigns.grabs, socket.assigns.series]

    assign(socket,
      active: Enum.sum_by(maps, &count_phase(&1, :active)),
      attention: Enum.sum_by(maps, &count_phase(&1, :attention))
    )
  end

  defp count_phase(map, phase),
    do: Enum.count(map, fn {_id, {_badge, item_phase}} -> item_phase == phase end)

  defp maybe_toast_movie(socket, movie, {:available, _phase}) do
    title = media_title(movie, socket.assigns.locale)
    toast(socket, :success, gettext("“%{title}” is now available.", title: title))
  end

  defp maybe_toast_movie(socket, movie, {_badge, :attention}) do
    title = media_title(movie, socket.assigns.locale)
    toast(socket, :warning, gettext("“%{title}” needs attention.", title: title))
  end

  defp maybe_toast_movie(socket, _movie, _entry), do: socket

  # A grab that just started needing attention: one toast per such grab.
  defp toast_new_grab_attention(socket, grabs) do
    old = socket.assigns.grabs

    grabs
    |> Enum.filter(fn {id, entry} ->
      needs_attention?(entry) and not needs_attention?(Map.get(old, id))
    end)
    |> Enum.reduce(socket, fn _grab, acc ->
      toast(acc, :warning, gettext("A download needs attention."))
    end)
  end

  # A series that just started needing attention (an anime hold): one titled toast per series.
  defp toast_new_series_attention(socket, held, series) do
    old = socket.assigns.series

    held
    |> Enum.filter(fn s ->
      needs_attention?(series[s.id]) and not needs_attention?(Map.get(old, s.id))
    end)
    |> Enum.reduce(socket, fn s, acc ->
      title = media_title(s, acc.assigns.locale)
      toast(acc, :warning, gettext("“%{title}” needs attention.", title: title))
    end)
  end

  defp needs_attention?({_badge, phase}), do: phase == :attention
  defp needs_attention?(nil), do: false

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
