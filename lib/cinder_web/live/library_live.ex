defmodule CinderWeb.LibraryLive do
  @moduledoc """
  Admin managed-catalog at `/library`: every movie (cancel / delete; drill into
  `/movies/:id` for edit and pipeline actions) and every added series (cancel / delete; drill into
  `/series/:id` for per-episode monitoring). Merges the old `/movies` page and the Discover
  "Added series" block.

  One type at a time, picked by the `?type=` query param (`tv`, else movies) and read in
  `mount/3` — the tab links are `navigate`, not `patch`, so switching scrolls back to the top
  and drops the filter with the remount instead of needing reset code. A title filter narrows
  the visible grid; `@movies`/`@series` stay canonical (the PubSub handlers, `find_movie/2` and
  `run_series_op/3` all resolve against them) and filtering *and sorting* happen at render.

  Sorting is deliberately not a query `order_by`: `upsert_by_id/2` mutates `@movies` in place on
  every broadcast, so a database order would be a lie the first time an update changes a sorted
  field. `?sort=` *is* in the URL even though the filter isn't — a reconnect is a fresh `mount/3`
  against the client's current URL, so a plain assign would silently reset the sort on any network
  blip. (The filter stays transient on purpose: unbounded free text, and a momentary
  find-this-one-thing action rather than a presentation mode held across several actions.) The
  patch uses `replace: true` so a run of select changes doesn't bury the previous page under
  history entries — Back from `/movies/:id` still returns to the sorted list.

  Admin-gated by the `:admin` live_session; every mutation routes through the existing
  `Catalog` functions — no pipeline or gate change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     socket
     |> assign(
       movies: Catalog.list_movies(),
       tab: if(params["type"] == "tv", do: :tv, else: :movies),
       filter: "",
       confirming: nil,
       delete_files: false
     )
     |> assign_series()}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, :sort, parse_sort(params["sort"]))}

  # --- movies ---
  @impl true
  def handle_event("ask_cancel_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :cancel, id})}

  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, delete_files: false)}

  def handle_event("confirm_cancel_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.cancel_movie(movie, actor) do
      {:noreply,
       socket
       |> assign(confirming: nil, movies: Catalog.list_movies())
       |> put_flash(:info, gettext("Movie cancelled."))}
    else
      {:error, :not_cancellable} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("That movie can't be cancelled."))}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't cancel that movie."))}
    end
  end

  def handle_event("confirm_delete_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <-
           Catalog.delete_movie(movie, actor, delete_files: socket.assigns.delete_files) do
      {:noreply,
       socket
       |> assign(confirming: nil, delete_files: false)
       |> put_flash(:info, gettext("Movie deleted."))}
    else
      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete that movie."))}
    end
  end

  # --- series ---
  def handle_event("ask_cancel_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :cancel, id})}

  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :delete, id}, delete_files: false)}

  def handle_event("confirm_cancel_series", %{"id" => id}, socket),
    do:
      run_series_op(
        socket,
        id,
        &Catalog.cancel_series/2,
        gettext("Series cancelled."),
        gettext("Couldn't cancel the series.")
      )

  def handle_event("confirm_delete_series", %{"id" => id}, socket) do
    flag = socket.assigns.delete_files

    run_series_op(
      socket,
      id,
      fn series, actor -> Catalog.delete_series(series, actor, delete_files: flag) end,
      gettext("Series deleted."),
      gettext("Couldn't delete the series.")
    )
  end

  # --- shared ---
  # Narrows the rendered grid only — never written back onto @movies/@series, which stay the
  # authority for the PubSub handlers and the cancel/delete lookups. Drops any open confirm:
  # filtering its card away would otherwise strand the aria-live alert, to be re-announced when
  # the filter clears.
  def handle_event("filter", %{"filter" => filter}, socket) when is_binary(filter),
    do: {:noreply, assign(socket, filter: filter, confirming: nil, delete_files: false)}

  # Its own form and its own event on purpose: dropped into the filter form, the "filter" clause
  # above still matches (extra map keys are allowed) and the sort change is swallowed silently.
  def handle_event("sort", %{"sort" => value}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: library_path(socket.assigns.tab, parse_sort(value)),
         replace: true
       )}

  def handle_event("toggle_delete_files", _params, socket),
    do: {:noreply, assign(socket, delete_files: !socket.assigns.delete_files)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, delete_files: false)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket), do: {:noreply, assign_series(socket)}

  def handle_info({:series_deleted, _id}, socket), do: {:noreply, assign_series(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find_movie(socket, id), do: find_by_id(socket.assigns.movies, to_string(id))

  # The series list and its size map always move together — every `episodes.imported_size` writer
  # broadcasts `{:series_updated, _}` on the topic this view subscribes to, so refreshing one
  # without the other is the only way they can drift.
  #
  # Gated on the tab because `item_size/2` never reads the map on the movies tab (a `Series` has
  # no `imported_size` field of its own), and `@tab` is fixed for the view's lifetime — the tab
  # links are `navigate`, i.e. a full remount. That keeps the aggregate off the default landing
  # tab entirely. ponytail: the TV tab recomputes it per broadcast — measured ~2.6 ms at 5k
  # episode rows, so the burst during a season-pack import is affordable; if it ever shows up,
  # add a covering partial index on `episodes(season_id, file_path, imported_size)
  # WHERE file_path IS NOT NULL`.
  defp assign_series(socket) do
    sizes = if socket.assigns.tab == :tv, do: Catalog.series_library_sizes(), else: %{}
    assign(socket, series: Catalog.list_series(), series_sizes: sizes)
  end

  # Render-time narrowing of the active tab's list. Case-insensitive substring on the title.
  defp visible(items, ""), do: items

  defp visible(items, filter) do
    needle = String.downcase(filter)
    Enum.filter(items, &String.contains?(String.downcase(&1.title), needle))
  end

  # Render-time ordering of the active tab's list. `:added` is the list as loaded (`desc: id`),
  # so the default costs nothing.
  defp sort_items(items, :title, _sizes), do: Enum.sort_by(items, &{fold(&1.title), -&1.id})

  defp sort_items(items, :size, sizes),
    do: Enum.sort_by(items, &desc_key(item_size(&1, sizes), &1.id))

  defp sort_items(items, :year, _sizes), do: Enum.sort_by(items, &desc_key(&1.year, &1.id))
  defp sort_items(items, _added, _sizes), do: items

  # Descending with nils last, newest id first on a tie: `false < true` in Elixir term order parks
  # the nils at the end without a second pass.
  defp desc_key(value, id), do: {is_nil(value), -(value || 0), -id}

  # Bytes on disk. A movie carries its own size; a series' is summed per-file in SQL. The
  # `file_path` guard keeps both tabs meaning the same thing — `Catalog.retry_movie/1` clears
  # `file_path` but leaves `imported_size`, so a retried movie would otherwise sort by (and print)
  # bytes it no longer has, while the series aggregate is already `file_path`-guarded.
  defp item_size(%{file_path: nil}, _sizes), do: nil
  defp item_size(%{imported_size: size}, _sizes), do: size
  defp item_size(%{id: id}, sizes), do: sizes[id]

  # Case- and accent-folded sort key, so "Amélie" lands next to "Amelie" instead of after "Zorro".
  # Codepoint order, not locale collation — "Eclair" still sorts before "Éclair" rather than
  # interleaving, which is fine at household scale. Total, like `Cinder.Acquisition.nfd/1`:
  # `characters_to_nfd_binary/1` returns `{:error, _, _}` on malformed UTF-8, and a raise here
  # would happen inside `render/1` and take the whole page down.
  defp fold(title) do
    case :unicode.characters_to_nfd_binary(title) do
      binary when is_binary(binary) -> String.downcase(binary)
      _ -> String.downcase(title)
    end
  end

  # Allowlist, never `String.to_atom/1` on a client-supplied param. Unknown → the default.
  defp parse_sort("title"), do: :title
  defp parse_sort("size"), do: :size
  defp parse_sort("year"), do: :year
  defp parse_sort(_), do: :added

  # A function, not a module attribute: the labels are translated at runtime, per locale.
  defp sort_options do
    [
      {gettext("Recently added"), "added"},
      {gettext("Title (A–Z)"), "title"},
      {gettext("Size (largest first)"), "size"},
      {gettext("Year (newest first)"), "year"}
    ]
  end

  # One builder for the sort patch target *and* both tab hrefs, so they can't drift: a patch that
  # dropped `type=tv` would leave the URL saying Movies while the TV tab renders, and the next
  # reconnect — a fresh `mount/3` against that URL — would silently flip the operator's tab.
  defp library_path(:tv, sort), do: ~p"/library?type=tv&sort=#{sort}"
  defp library_path(:movies, sort), do: ~p"/library?sort=#{sort}"

  # /library is admin-gated by its route, so no in-handler role re-check (Discover needed
  # one because it lived on a non-admin route).
  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    actor = socket.assigns.current_scope.user
    series = find_by_id(socket.assigns.series, id)

    case series && op.(series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> assign_series()
         |> put_flash(:info, ok_msg)}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, err_msg)}
    end
  end

  @impl true
  def render(assigns) do
    items = if assigns.tab == :tv, do: assigns.series, else: assigns.movies

    assigns =
      assign(
        assigns,
        :visible,
        items |> visible(assigns.filter) |> sort_items(assigns.sort, assigns.series_sizes)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Library")}
        <:subtitle>{gettext("Manage movies and added series.")}</:subtitle>
      </.header>

      <%!-- Navigation, not an ARIA tablist: these are links that change the URL, and the
            roving-tabindex/arrow-key behaviour role="tab" promises has no JS behind it here.
            aria-current matches the nav_item/locale_switcher pattern in layouts.ex. --%>
      <nav class="tabs tabs-box mb-4" aria-label={gettext("Library")}>
        <.link
          id="library-tab-movies"
          navigate={library_path(:movies, @sort)}
          aria-current={@tab == :movies && "page"}
          class={["tab min-h-11", @tab == :movies && "tab-active"]}
        >
          {gettext("Movies")} ({length(@movies)})
        </.link>
        <.link
          id="library-tab-tv"
          navigate={library_path(:tv, @sort)}
          aria-current={@tab == :tv && "page"}
          class={["tab min-h-11", @tab == :tv && "tab-active"]}
        >
          {gettext("Series")} ({length(@series)})
        </.link>
      </nav>

      <%!-- The input must live inside a form: LiveView's client throws "form events require
            the input to be inside a form" on a bare phx-change input, which LiveViewTest does
            not reproduce. No spinner here — unlike Discover's search there is no roundtrip. --%>
      <div class="mb-6 flex flex-col gap-2 sm:flex-row sm:items-start">
        <%!-- The visible label is what keeps this input and the sort select on one baseline:
              `.input type="select"` wraps in `div.fieldset` with a label span above the control,
              so a bare sibling sits higher by exactly that label (cf. #166). --%>
        <form id="library-filter-form" phx-change="filter" phx-submit="filter" class="grow">
          <div class="fieldset mb-2">
            <label for="library-filter">
              <span class="label mb-1">{gettext("Filter by title")}</span>
              <input
                type="search"
                id="library-filter"
                name="filter"
                value={@filter}
                phx-debounce="300"
                autocomplete="off"
                placeholder={gettext("Filter by title…")}
                class="input input-lg w-full min-h-11"
              />
            </label>
          </div>
        </form>

        <%!-- Its own form, not a second field on the filter form: the filter handler would match
              the combined params and swallow the sort change without a warning. --%>
        <form id="library-sort-form" phx-change="sort" phx-submit="sort" class="sm:w-64">
          <.input
            id="library-sort"
            name="sort"
            type="select"
            label={gettext("Sort by")}
            value={to_string(@sort)}
            options={sort_options()}
            class="select select-lg w-full min-h-11"
          />
        </form>
      </div>

      <section :if={@tab == :movies}>
        <h2 class="sr-only">{gettext("Movies")}</h2>
        <.empty_state
          :if={@visible == []}
          icon="hero-film"
          title={if @filter == "", do: gettext("No movies yet"), else: gettext("No matches")}
          message={if @filter == "", do: gettext("Requested movies appear here."), else: nil}
        />
        <div
          :if={@visible != []}
          id="movies-list"
          class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 2xl:grid-cols-5 gap-4"
        >
          <div
            :for={m <- @visible}
            id={"movie-#{m.id}"}
            class={[
              "space-y-2",
              @confirming in [
                {:movie, :cancel, to_string(m.id)},
                {:movie, :delete, to_string(m.id)}
              ] &&
                "col-span-2 sm:col-span-3 lg:col-span-4 2xl:col-span-5"
            ]}
          >
            <.link navigate={~p"/movies/#{m.id}"} class="block max-w-xs">
              <.media_card poster_path={m.poster_path} title={m.title} year={m.year} type={:movie}>
                <p
                  :if={humanize_bytes(item_size(m, @series_sizes))}
                  class="text-xs tabular-nums text-base-content/60"
                >
                  {humanize_bytes(item_size(m, @series_sizes))}
                </p>
                <.status_badge
                  kind={:movie}
                  status={movie_badge_status(m)}
                  progress={m.download_progress}
                  speed={m.download_speed}
                  eta={m.download_eta}
                  class="h-auto break-words text-center"
                />
              </.media_card>
            </.link>

            <div class="flex flex-wrap gap-2">
              <.button
                :if={Catalog.cancellable?(m)}
                type="button"
                variant="warning"
                size="sm"
                phx-click="ask_cancel_movie"
                phx-value-id={m.id}
              >
                {gettext("Cancel")}
              </.button>
              <.button
                :if={not Catalog.cancellable?(m)}
                type="button"
                variant="danger"
                size="sm"
                phx-click="ask_delete_movie"
                phx-value-id={m.id}
              >
                {gettext("Delete")}
              </.button>
            </div>

            <.confirm_action
              :if={@confirming == {:movie, :cancel, to_string(m.id)}}
              id={"confirm-cancel-movie-#{m.id}"}
              on_confirm="confirm_cancel_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label={gettext("Cancel movie")}
              variant="warning"
            >
              <:caveat>{gettext("Cancel this movie and remove its download?")}</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:movie, :delete, to_string(m.id)}}
              id={"confirm-delete-movie-#{m.id}"}
              on_confirm="confirm_delete_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label={gettext("Delete")}
              checkbox_event="toggle_delete_files"
              checkbox_checked={@delete_files}
              checkbox_label={gettext("Also delete the file from disk")}
            >
              <:caveat>{gettext("Delete this movie's record?")}</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>

      <section :if={@tab == :tv}>
        <h2 class="sr-only">{gettext("Series")}</h2>
        <.empty_state
          :if={@visible == []}
          icon="hero-tv"
          title={if @filter == "", do: gettext("No series added yet"), else: gettext("No matches")}
          message={if @filter == "", do: gettext("Add a show from Discover."), else: nil}
        />
        <div
          :if={@visible != []}
          id="series-list"
          class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 2xl:grid-cols-5 gap-4"
        >
          <div
            :for={s <- @visible}
            id={"series-row-#{s.id}"}
            class={[
              "space-y-2",
              @confirming in [
                {:series, :cancel, to_string(s.id)},
                {:series, :delete, to_string(s.id)}
              ] &&
                "col-span-2 sm:col-span-3 lg:col-span-4 2xl:col-span-5"
            ]}
          >
            <.link navigate={~p"/series/#{s.id}"} class="block max-w-xs">
              <.media_card poster_path={s.poster_path} title={s.title} year={s.year} type={:tv}>
                <p
                  :if={humanize_bytes(item_size(s, @series_sizes))}
                  class="text-xs tabular-nums text-base-content/60"
                >
                  {humanize_bytes(item_size(s, @series_sizes))}
                </p>
                <.status_badge
                  kind={:monitored}
                  status={s.monitored}
                  class="h-auto break-words text-center"
                />
              </.media_card>
            </.link>

            <div class="flex flex-wrap gap-2">
              <.button
                type="button"
                variant="warning"
                size="sm"
                phx-click="ask_cancel_series"
                phx-value-id={s.id}
              >{gettext("Cancel")}</.button>
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="ask_delete_series"
                phx-value-id={s.id}
              >{gettext("Delete")}</.button>
            </div>

            <.confirm_action
              :if={@confirming == {:series, :cancel, to_string(s.id)}}
              id={"confirm-cancel-series-#{s.id}"}
              on_confirm="confirm_cancel_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label={gettext("Cancel & unmonitor")}
              variant="warning"
            >
              <:caveat>{gettext("Cancel & unmonitor this series?")}</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:series, :delete, to_string(s.id)}}
              id={"confirm-delete-series-#{s.id}"}
              on_confirm="confirm_delete_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label={gettext("Delete")}
              checkbox_event="toggle_delete_files"
              checkbox_checked={@delete_files}
              checkbox_label={gettext("Also delete files from disk")}
            >
              <:caveat>{gettext("Delete this series and its seasons/episodes?")}</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
