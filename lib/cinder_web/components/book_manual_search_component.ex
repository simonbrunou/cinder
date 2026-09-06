defmodule CinderWeb.BookManualSearchComponent do
  @moduledoc """
  Manual release-search panel for one monitored `:ebook` book target — the books analogue of
  `CinderWeb.ManualSearchComponent`, but not built on it: `Acquisition.Books.candidates/2` already
  returns the partitioned `%{accepted:, rejected:, complete?:}` answer, not the flat verdict list
  the movie/TV panel folds at render time, and every non-async internal of that component (anime
  policy, TV seasons, the language-pool sweep, video-only rejection atoms) has no book equivalent.
  What is reused is the pattern: run the search off-process with `start_async`, render
  loading/error/loaded states, and forward a chosen release to the parent LiveView with
  `send(self(), {:manual_grab, :book, target, release})` rather than writing anything itself.

  Required assigns: `id`, `target` (a `%Cinder.Books.BookTarget{}`), `work` (the fully-preloaded
  `%Cinder.Books.Work{}` `Acquisition.Books.candidates/2` wants — editions/credits/series
  preloaded, e.g. from `Cinder.Books.get_work/1`). A `results:` assign (the raw
  `Acquisition.Books.candidates/2` map) is consumed directly and skips the async fetch — useful
  for tests, mirroring `CinderWeb.ManualSearchComponent`'s own `results:` escape hatch.

  `/books/:id` has one fixed target per media kind and no season selector, so the target itself
  never changes underneath one panel instance — but its `preferred_language` can, from the same
  page's language picker while the panel stays open (#495). A language change invalidates and
  restarts the search exactly like `ManualSearchComponent`'s own target/profile/policy context
  diff: the old accepted/rejected partition was scored against the superseded preference and
  must never stay grabbable under the new one.
  """
  use CinderWeb, :live_component

  import CinderWeb.LiveHelpers, only: [humanize_bytes: 1]

  require Logger

  alias Cinder.Acquisition.Books
  alias Cinder.Download

  @impl true
  def update(assigns, socket) do
    search_context = search_context(assigns)
    context_changed? = search_context_changed?(socket, search_context)

    socket =
      socket
      |> assign(assigns)
      |> assign(:search_context, search_context)
      # A "grab" event racing an in-flight/failed search must never dereference an unset
      # `:results` — this is present from the very first render, never only once `handle_async`
      # or a preseed sets it, mirroring `ManualSearchComponent`'s own `results: []` default.
      |> assign_new(:results, fn -> %{accepted: [], rejected: [], complete?: true} end)
      |> maybe_cancel_stale_search(context_changed?)

    socket =
      cond do
        # Test / pre-seeded path: results supplied directly, skip the async fetch. Cancels any
        # in-flight search first — a caller that starts a connected search and then supplies
        # `results:` must not have the earlier task's late completion clobber the preseed.
        preseeded?(assigns) ->
          socket |> cancel_async(:search) |> assign(:state, :loaded)

        # The target's language changed while the panel stayed open — the old accepted/rejected
        # partition was scored against a superseded preference and must not survive. Cancelling
        # the in-flight task AND starting a fresh one under a new ref means Phoenix's own
        # async-ref tracking drops a delayed pre-change search that completes after this point
        # (`Phoenix.LiveView.Async.prune_current_async/3` — a result whose ref no longer matches
        # the socket's current one for `:search` is silently discarded), so it can never land.
        context_changed? ->
          restart_search(socket)

        not is_nil(socket.assigns[:state]) ->
          socket

        connected?(socket) ->
          socket |> assign(state: :loading) |> start_search()

        true ->
          assign(socket, :state, :loading)
      end

    {:ok, socket}
  end

  defp preseeded?(assigns), do: Map.has_key?(assigns, :results) and not is_nil(assigns[:results])

  # The only two `Books.candidates/2` inputs that can change while one panel instance stays
  # mounted: the target never swaps under a fixed `/books/:id` panel, but `preferred_language`
  # does, from the page's own language picker (`BookDetailLive.handle_event("change_language",
  # ...)`, which broadcasts and reloads `@target`).
  defp search_context(assigns), do: {assigns.target.id, assigns.target.preferred_language}

  defp search_context_changed?(socket, current) do
    previous = socket.assigns[:search_context] || previous_search_context(socket.assigns)
    not is_nil(previous) and previous != current
  end

  defp previous_search_context(%{target: _target} = assigns), do: search_context(assigns)
  defp previous_search_context(_assigns), do: nil

  defp maybe_cancel_stale_search(socket, true), do: cancel_async(socket, :search)
  defp maybe_cancel_stale_search(socket, false), do: socket

  defp restart_search(socket) do
    socket =
      assign(socket, state: :loading, results: %{accepted: [], rejected: [], complete?: true})

    if connected?(socket), do: start_search(socket), else: socket
  end

  defp start_search(socket) do
    %{work: work, target: target} = socket.assigns

    start_async(socket, :search, fn ->
      Books.candidates(work,
        protocols: Download.available_protocols(),
        language: target.preferred_language,
        release_blocklist: Cinder.Books.blocked_release_titles(target.id)
      )
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, result}}, socket),
    do: {:noreply, assign(socket, state: :loaded, results: result)}

  def handle_async(:search, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, :state, :error)}

  def handle_async(:search, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :state, :error)}

  @impl true
  def handle_event("grab", %{"index" => index}, socket) do
    case fetch_release(socket.assigns.results.accepted, index) do
      {release, _evidence} ->
        send(self(), {:manual_grab, :book, socket.assigns.target, release})

      nil ->
        :noop
    end

    {:noreply, socket}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # phx-value-index arrives as a string; resolve it to the {release, evidence} tuple by position —
  # not by title, for the same multi-tracker-dupe reason `ManualSearchComponent` resolves by index.
  defp fetch_release(accepted, index) when is_binary(index) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 -> Enum.at(accepted, i)
      _ -> nil
    end
  end

  defp fetch_release(_accepted, _index), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-200 mt-2 p-3">
      <div :if={@state == :loading} class="flex items-center gap-2 text-sm">
        <span class="loading loading-spinner loading-sm" />{gettext("Searching releases…")}
      </div>

      <p :if={@state == :error} class="text-sm text-error">
        {gettext("Couldn't reach the indexer. Try again.")}
      </p>

      <div :if={@state == :loaded}>
        <p :if={not @results.complete?} class="mb-2 text-xs text-warning">
          {gettext("Some indexers could not be reached; results may be incomplete.")}
        </p>

        <p :if={@results.accepted == [] and @results.rejected == []} class="text-sm">
          {gettext("No releases found.")}
        </p>

        <ul :if={@results.accepted != []} class="space-y-1">
          <li
            :for={{{release, evidence}, index} <- Enum.with_index(@results.accepted)}
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <span class="min-w-0 flex-1 truncate" title={release.title}>{release.title}</span>
            <span class="badge badge-xs">{format_label(evidence.format)}</span>
            <span class="badge badge-xs badge-ghost">{release_language_label(evidence.language)}</span>
            <span :if={evidence.retail?} class="badge badge-xs badge-success">
              {gettext("retail")}
            </span>
            <span :if={humanize_bytes(evidence.size)} class="text-xs text-base-content/60">
              {humanize_bytes(evidence.size)}
            </span>
            <.button
              type="button"
              size="xs"
              variant="ghost"
              phx-target={@myself}
              phx-click="grab"
              phx-value-index={index}
              phx-disable-with={gettext("Grabbing…")}
              data-confirm={replace?(@target) && gettext("This replaces the current file: continue?")}
            >
              {gettext("Grab")}
            </.button>
          </li>
        </ul>

        <ul :if={@results.rejected != []} class="mt-2 space-y-1">
          <li
            :for={{release, reason} <- @results.rejected}
            class="flex flex-wrap items-center gap-2 text-sm text-base-content/60"
          >
            <span class="min-w-0 flex-1 truncate" title={release.title}>{release.title}</span>
            <span class="text-xs text-warning">{reject_reason_text(reason)}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp replace?(%{status: :available}), do: true
  defp replace?(_target), do: false

  defp format_label(format) when is_atom(format),
    do: format |> Atom.to_string() |> String.upcase()

  defp release_language_label(language) when language in [nil, ""], do: gettext("untagged")
  defp release_language_label(language), do: language

  # One clause per `Cinder.Acquisition.BookScorer.reasons/0` atom — kept in sync by
  # `test/cinder_web/components/book_manual_search_component_test.exs`'s exhaustiveness test,
  # which iterates `BookScorer.reasons/0` and fails if any atom falls through to the fallback
  # clause below.
  defp reject_reason_text(:format_unknown), do: gettext("unrecognized format")
  defp reject_reason_text(:format_rejected), do: gettext("format not accepted")
  defp reject_reason_text(:format_contradictory), do: gettext("contradictory format claims")
  defp reject_reason_text(:author_mismatch), do: gettext("author doesn't match")
  defp reject_reason_text(:title_mismatch), do: gettext("title doesn't match")
  defp reject_reason_text(:title_unfoldable), do: gettext("title doesn't match")
  defp reject_reason_text(:language_mismatch), do: gettext("language doesn't match")
  defp reject_reason_text(:size_out_of_band), do: gettext("outside expected size")
  defp reject_reason_text(:blocked_term), do: gettext("contains a blocked term")
  defp reject_reason_text(:blocklisted), do: gettext("already tried and failed")

  defp reject_reason_text(:collection_ambiguous),
    do: gettext("omnibus/collection, not this work")

  defp reject_reason_text(:abridged_edition), do: gettext("abridged edition")
  defp reject_reason_text(:wrong_protocol), do: gettext("no client for protocol")

  # Fail-safe, not fail-silent-to-a-user: a reason the scorer added and this dictionary never
  # learned about is logged for whoever ships the next scorer change, and rendered as generic
  # copy — never the atom's own name (`to_string/1`/`inspect/1`) reaching an operator.
  defp reject_reason_text(reason) do
    Logger.warning("book manual search: unrecognized rejection reason #{inspect(reason)}")
    gettext("rejected")
  end
end
