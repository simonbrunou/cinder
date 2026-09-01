defmodule CinderWeb.LibraryLive do
  @moduledoc """
  Admin managed-catalog at `/library`: every movie (cancel / delete; drill into
  `/movies/:id` for edit and pipeline actions), every added series (cancel / delete; drill into
  `/series/:id` for per-episode monitoring), and every book target (inline Pause/Resume, plus a
  `?status=wanted|held` filter; drill into `/books/:id` for retry, blocklist, search/grab, and
  language). Merges the old `/movies` page and the Discover "Added series" block.

  One type at a time, picked by the `?type=` query param (`tv`/`books`, else movies) and read in
  `mount/3` via `parse_tab/1`'s allowlist — same discipline as `parse_sort/1` below, never
  `String.to_atom/1` on a client-supplied param. The tab links are `navigate`, not `patch`, so
  switching scrolls back to the top and drops the filter with the remount instead of needing
  reset code. A title filter narrows the visible grid; `@movies`/`@series`/`@books` stay canonical
  (the PubSub handlers, `find_movie/2` and `run_series_op/3` all resolve against them) and
  filtering *and sorting* happen at render.

  Sorting is deliberately not a query `order_by`: `upsert_by_id/2` mutates `@movies` in place on
  every broadcast, so a database order would be a lie the first time an update changes a sorted
  field. `?sort=` *is* in the URL even though the filter isn't — a reconnect is a fresh `mount/3`
  against the client's current URL, so a plain assign would silently reset the sort on any network
  blip. (The filter stays transient on purpose: unbounded free text, and a momentary
  find-this-one-thing action rather than a presentation mode held across several actions.) The
  patch uses `replace: true` so a run of select changes doesn't bury the previous page under
  history entries — Back from `/movies/:id` still returns to the sorted list.

  Admin-gated by the `:admin` live_session; every mutation routes through the existing
  `Catalog`/`Books` functions. The books tab writes only `Books.pause_target/1` and
  `resume_target/1` — heavier decisions (retry, blocklist, grab) stay on `/books/:id`.
  Live via the `movies` + `series` topics unconditionally, matching how both tabs' counts are
  always visible in the nav regardless of which is active. The books topic is the one exception —
  subscribed only when `@tab == :books`, not unconditionally like the other two: unlike
  movies/series, a book target's own broadcasts (`{:book_target_updated, _}`,
  `{:book_grab_deleted, _}` — see `Cinder.Books.Grabs.delete/1`) are frequent, pipeline-internal
  events with no in-place-mutation handler here (no `upsert_by_id/2` equivalent for a single
  target), so staying subscribed while sitting on a different tab would mean re-querying
  `Books.list_targets/0` in full for updates nothing on screen reflects. The `@books` list and its
  nav count are still loaded on every mount regardless of tab (cheap, no join), same as
  `@movies`/`@series`; only the live-update subscription and the size aggregate are tab-gated,
  the latter mirroring `assign_series/1`'s own existing `series_sizes` gate exactly. A catch-all
  `handle_info/2` clause absorbs every book broadcast this view doesn't otherwise act on.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers
  import CinderWeb.BookComponents, only: [book_state_badge: 1]

  alias Cinder.Books
  alias Cinder.Books.{BookTarget, Grabs}
  alias Cinder.Catalog

  @impl true
  def mount(params, _session, socket) do
    tab = parse_tab(params["type"])

    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      if tab == :books, do: Books.subscribe_targets()
    end

    {:ok,
     socket
     |> assign(
       movies: Catalog.list_movies(),
       tab: tab,
       filter: "",
       confirming: nil,
       delete_files: false
     )
     |> assign_series()
     |> assign_books()}
  end

  # `status`, like `sort`, is re-derived from the URL on every call — not just at mount — so a
  # sort change's `push_patch` (which now carries `status` through, see `handle_event("sort", …)`
  # below) restores it after a reconnect exactly like `sort` already does; only `?type=` behaves
  # differently, since a tab switch is a `navigate` (fresh `mount/3`), never a patch.
  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       assign(socket, sort: parse_sort(params["sort"]), status: parse_status(params["status"]))}

  # --- movies ---
  @impl true
  def handle_event("ask_cancel_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :cancel, id})}

  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, delete_files: false)}

  def handle_event("confirm_cancel_movie", %{"id" => id}, socket) when is_binary(id) do
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

  def handle_event("confirm_delete_movie", %{"id" => id}, socket) when is_binary(id) do
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

  # --- books ---
  # `Books.pause_target/1` is the choke-point: it refuses `{:error, :grab_in_progress}` if a
  # `book_grabs` row exists, closing the race the render-side `Grabs.for_target/1` guard (in the
  # template) only narrows. That refusal gets its own specific flash rather than the generic one.
  def handle_event("pause_target", %{"id" => id}, socket) when is_binary(id) do
    case find_book(socket, id) do
      nil ->
        {:noreply, socket}

      target ->
        case Books.pause_target(target) do
          {:ok, _paused} ->
            {:noreply,
             socket
             |> assign_books()
             |> put_flash(:info, gettext("Book target paused."))}

          {:error, :grab_in_progress} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "This target has a download in progress. Wait for it to finish before pausing."
               )
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't pause that book target."))}
        end
    end
  end

  def handle_event("resume_target", %{"id" => id}, socket) when is_binary(id) do
    case find_book(socket, id) do
      nil ->
        {:noreply, socket}

      target ->
        case Books.resume_target(target) do
          {:ok, _resumed} ->
            {:noreply,
             socket
             |> assign_books()
             |> put_flash(:info, gettext("Book target resumed."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't resume that book target."))}
        end
    end
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
         to: library_path(socket.assigns.tab, parse_sort(value), socket.assigns.status),
         replace: true
       )}

  def handle_event("toggle_delete_files", _params, socket),
    do: {:noreply, assign(socket, delete_files: !socket.assigns.delete_files)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, delete_files: false)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket), do: {:noreply, assign_series(socket)}

  def handle_info({:series_deleted, _id}, socket), do: {:noreply, assign_series(socket)}

  # A target's status/language changed, which the rendered badge (and possibly the size
  # aggregate, if it just reached `:available`) reflects. `@book_grabbing` (the Pause-button
  # gate) is refreshed here too, since it is recomputed as a whole every `assign_books/1` call —
  # cheaper than tracking it independently, at the cost of not being pushed live on a bare
  # `{:book_grab_updated, _}`/`{:book_grab_deleted, _}` (neither changes target status, so
  # neither reaches this clause); both still fall through to the catch-all below. That gap is
  # UX-only: `Books.pause_target/1`'s own `:grab_in_progress` refusal is the actual guard.
  def handle_info({:book_target_updated, _target}, socket), do: {:noreply, assign_books(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # `id` straight through, like `run_series_op/5` — `find_by_id/2` already does the `to_string/1`
  # on its own side. A `to_string/1` here would be applied to the CLIENT value, and a forged
  # `phx-value-id` carrying a map raises Protocol.UndefinedError. Its callers are guarded
  # `is_binary(id)` besides, so the conversion had nothing left to do.
  defp find_movie(socket, id), do: find_by_id(socket.assigns.movies, id)

  # Same guard/lookup discipline as `find_movie/2` — the canonical `@books` list, not the
  # filtered `@visible`, so a target hidden by the current `?status=`/text filter is still a
  # valid write target (matches `find_movie/2` searching `@movies`, not `@visible` movies).
  defp find_book(socket, id), do: find_by_id(socket.assigns.books, id)

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

  # `@books` loads on every mount regardless of tab (cheap: no join, same as `@movies`/`@series`)
  # so the nav count is always right even without a live subscription to that tab's topic — see
  # the moduledoc. The size aggregate and `@book_grabbing` (batched, not one `Grabs.for_target/1`
  # call per rendered row) are both gated on the tab exactly like `assign_series/1`'s own
  # `series_sizes` gate, for the same reason: nothing reads either off-tab.
  defp assign_books(socket) do
    on_books_tab? = socket.assigns.tab == :books
    sizes = if on_books_tab?, do: Books.target_sizes(), else: %{}
    grabbing = if on_books_tab?, do: Grabs.target_ids_in_progress(), else: MapSet.new()
    assign(socket, books: Books.list_targets(), book_sizes: sizes, book_grabbing: grabbing)
  end

  # Render-time narrowing of the active tab's list. Case-insensitive substring on the
  # LOCALIZED title, so filtering matches what's actually displayed.
  defp visible(items, "", _locale), do: items

  defp visible(items, filter, locale) do
    needle = String.downcase(filter)
    Enum.filter(items, &String.contains?(String.downcase(media_title(&1, locale)), needle))
  end

  # Render-time ordering of the active tab's list. `:added` is the list as loaded (`desc: id`),
  # so the default costs nothing. `:title` folds the LOCALIZED title, matching what's displayed.
  defp sort_items(items, :title, _sizes, locale),
    do: Enum.sort_by(items, &{fold_title(media_title(&1, locale)), -&1.id})

  defp sort_items(items, :size, sizes, _locale),
    do: Enum.sort_by(items, &desc_key(item_size(&1, sizes), &1.id))

  defp sort_items(items, :year, _sizes, _locale),
    do: Enum.sort_by(items, &desc_key(&1.year, &1.id))

  defp sort_items(items, _added, _sizes, _locale), do: items

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

  # Books' own filter/sort/size, additive alongside the movie/series functions above rather than
  # extended clauses on them: a `%BookTarget{}` has no `.title`/`.localizations` (its work does)
  # and no `.year` (its work's `first_published_on` does), so `media_title/2`/`&1.year` would
  # simply fail against it — the two families never share a struct shape to genuinely unify.
  defp book_visible(targets, ""), do: targets

  defp book_visible(targets, filter) do
    needle = String.downcase(filter)
    Enum.filter(targets, &String.contains?(String.downcase(&1.work.title), needle))
  end

  # `?status=` narrowing, applied after the text filter and before sort (same composition as
  # `book_visible/2` itself). `nil` (no/unknown `?status=`) is unfiltered — today's behavior.
  defp book_status_visible(targets, nil), do: targets
  defp book_status_visible(targets, status), do: Enum.filter(targets, &(&1.status == status))

  # Same four sort keys as `sort_items/4`, mapped onto a target's own fields — see the moduledoc.
  defp sort_book_items(targets, :title, _sizes),
    do: Enum.sort_by(targets, &{fold_title(&1.work.title), -&1.id})

  defp sort_book_items(targets, :size, sizes),
    do: Enum.sort_by(targets, &desc_key(book_item_size(&1, sizes), &1.id))

  defp sort_book_items(targets, :year, _sizes),
    do: Enum.sort_by(targets, &desc_key(book_year(&1), &1.id))

  defp sort_book_items(targets, _added, _sizes), do: targets

  defp book_year(%{work: %{first_published_on: %Date{} = date}}), do: date.year
  defp book_year(_target), do: nil

  # Bytes on disk, shown and sorted only once a target has something to show: `:available` is the
  # target-level analogue of a movie's `file_path` guard above — a `:monitored`/`:held` target has
  # no file yet, and `target_sizes/0`'s map simply has no key for it either way.
  defp book_item_size(%BookTarget{status: :available, id: id}, sizes), do: sizes[id]
  defp book_item_size(%BookTarget{}, _sizes), do: nil

  # Allowlist, never `String.to_atom/1` on a client-supplied param. Unknown → the default.
  defp parse_sort("title"), do: :title
  defp parse_sort("size"), do: :size
  defp parse_sort("year"), do: :year
  defp parse_sort(_), do: :added

  # Same allowlist discipline as `parse_sort/1` just above — never `String.to_atom/1` on the
  # client-supplied `?type=` param. Unknown or absent → the default `:movies`, matching the
  # pre-existing two-way `if params["type"] == "tv"` this replaces.
  defp parse_tab("tv"), do: :tv
  defp parse_tab("books"), do: :books
  defp parse_tab(_), do: :movies

  # Same allowlist discipline again — never `String.to_atom/1` on the client-supplied `?status=`
  # param. Unknown or absent → nil, the unfiltered default (unchanged pre-B5c behavior).
  defp parse_status("wanted"), do: :monitored
  defp parse_status("held"), do: :held
  defp parse_status(_), do: nil

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
  defp library_path(:books, sort), do: ~p"/library?type=books&sort=#{sort}"
  defp library_path(:movies, sort), do: ~p"/library?sort=#{sort}"

  # Same as `library_path/2`, but also threads the books `?status=` through — used only by the
  # sort patch (`handle_event("sort", …)`), which must preserve the operator's Wanted/Held
  # filter across a sort change (the same reason `?sort=` itself lives in the URL, per the
  # moduledoc). The plain tab-nav links below stay `library_path/2`: a tab switch is a
  # `navigate` (fresh `mount/3`), where dropping the filter is the existing, intentional reset.
  defp library_path(:books, sort, status) when not is_nil(status),
    do: ~p"/library?type=books&sort=#{sort}&status=#{status_param(status)}"

  defp library_path(tab, sort, _status), do: library_path(tab, sort)

  # Inverse of `parse_status/1`, for rebuilding the `?status=` query param from the assign.
  defp status_param(:monitored), do: "wanted"
  defp status_param(:held), do: "held"

  defp kind_label(:ebook), do: gettext("eBook")
  defp kind_label(:audiobook), do: gettext("Audiobook")

  defp contributor_names(work), do: Enum.map_join(work.credits, ", ", & &1.author.name)

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

  # Branches instead of extending the two-arg `visible/3`/`sort_items/4` pipe uniformly across
  # all three tabs — see `book_visible/2`'s own comment for why a `%BookTarget{}` can't share
  # that pipe's shape.
  defp visible_for_tab(%{tab: :books} = assigns) do
    assigns.books
    |> book_visible(assigns.filter)
    |> book_status_visible(assigns.status)
    |> sort_book_items(assigns.sort, assigns.book_sizes)
  end

  defp visible_for_tab(%{tab: :tv} = assigns) do
    assigns.series
    |> visible(assigns.filter, assigns.locale)
    |> sort_items(assigns.sort, assigns.series_sizes, assigns.locale)
  end

  defp visible_for_tab(assigns) do
    assigns.movies
    |> visible(assigns.filter, assigns.locale)
    |> sort_items(assigns.sort, assigns.series_sizes, assigns.locale)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_for_tab(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.header>
        {gettext("Library")}
        <:subtitle>{gettext("Manage movies, added series, and book targets.")}</:subtitle>
        <:actions>
          <.link id="adopt-library-link" navigate={~p"/library/adopt"} class="btn btn-primary">
            {gettext("Adopt existing library")}
          </.link>
        </:actions>
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
        <.link
          id="library-tab-books"
          navigate={library_path(:books, @sort)}
          aria-current={@tab == :books && "page"}
          class={["tab min-h-11", @tab == :books && "tab-active"]}
        >
          {gettext("Books")} ({length(@books)})
        </.link>
        <.link
          :if={@tab == :books}
          id="library-books-wanted"
          navigate={~p"/library?type=books&status=wanted"}
          aria-current={@status == :monitored && "page"}
          class={["tab min-h-11 tab-sm", @status == :monitored && "tab-active"]}
        >
          {gettext("Wanted")}
        </.link>
        <.link
          :if={@tab == :books}
          id="library-books-held"
          navigate={~p"/library?type=books&status=held"}
          aria-current={@status == :held && "page"}
          class={["tab min-h-11 tab-sm", @status == :held && "tab-active"]}
        >
          {gettext("Held")}
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
              <.media_card
                poster_path={m.poster_path}
                title={media_title(m, @locale)}
                year={m.year}
                type={:movie}
              >
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
                  style="min-width: 0"
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
              <.media_card
                poster_path={s.poster_path}
                title={media_title(s, @locale)}
                year={s.year}
                type={:tv}
              >
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
                  style="min-width: 0"
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

      <section :if={@tab == :books}>
        <h2 class="sr-only">{gettext("Books")}</h2>
        <.empty_state
          :if={@visible == []}
          icon="hero-book-open"
          title={
            if @filter == "" and is_nil(@status),
              do: gettext("No books yet"),
              else: gettext("No matches")
          }
          message={
            if @filter == "" and is_nil(@status),
              do: gettext("Approved books appear here."),
              else: nil
          }
        />
        <%!-- book_cards/1's own grid — sm:grid-cols-2 lg:grid-cols-3, not the 5-column poster
              grid above: these are text cards (no cover art; see book_components.ex), so they
              need the wider columns that grid already uses everywhere else books render. --%>
        <div :if={@visible != []} id="books-list" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <article
            :for={t <- @visible}
            id={"book-target-row-#{t.id}"}
            class="card bg-base-200 shadow-sm"
          >
            <div class="card-body gap-3 p-4">
              <h3 class="card-title text-base leading-tight">
                <.link navigate={~p"/books/#{t.work_id}"} class="link link-hover">
                  {t.work.title}
                </.link>
              </h3>

              <p :if={t.work.credits != []} class="text-sm text-base-content/70">
                {contributor_names(t.work)}
              </p>

              <div class="flex flex-wrap items-center gap-2">
                <span class="badge badge-sm badge-ghost">{kind_label(t.media_kind)}</span>
                <span
                  :if={humanize_bytes(book_item_size(t, @book_sizes))}
                  class="text-xs tabular-nums text-base-content/60"
                >
                  {humanize_bytes(book_item_size(t, @book_sizes))}
                </span>
              </div>

              <.book_state_badge
                id={"library-book-state-#{t.id}"}
                kind={t.media_kind}
                state={book_badge_state(nil, t.status)}
              />

              <%!-- Cheap/reversible only: a `:held` row's Retry/Clear-blocklist stay on
                    `/books/:id`, where the hold reason is already rendered. `@book_grabbing`
                    here is UX only — hiding a button that would visibly fail — the actual
                    safety boundary is `Books.pause_target/1`'s own `:grab_in_progress`
                    refusal, so a grab created after this batched read still gets refused
                    server-side rather than accepted. --%>
              <div :if={t.status in [:monitored, :unmonitored]} class="flex flex-wrap gap-2">
                <.button
                  :if={t.status == :monitored and not MapSet.member?(@book_grabbing, t.id)}
                  type="button"
                  variant="warning"
                  size="sm"
                  phx-click="pause_target"
                  phx-value-id={t.id}
                >
                  {gettext("Pause")}
                </.button>
                <.button
                  :if={t.status == :unmonitored}
                  type="button"
                  variant="primary"
                  size="sm"
                  phx-click="resume_target"
                  phx-value-id={t.id}
                >
                  {gettext("Resume")}
                </.button>
              </div>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
