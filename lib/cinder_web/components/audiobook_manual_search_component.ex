defmodule CinderWeb.AudiobookManualSearchComponent do
  @moduledoc """
  Manual release-search panel for one monitored `:audiobook` book target — the
  `CinderWeb.BookManualSearchComponent` sibling, not built on it (B7d, mirroring that
  component's own note against building on the movie/TV panel): `Acquisition.Audiobooks` is a
  different module with a different scorer reason vocabulary source
  (`Cinder.Acquisition.AudiobookScorer.reasons/0`, not `BookScorer.reasons/0` — the same closed
  set of atoms today, but a distinct dictionary this component owns so the two families can
  diverge independently later without one editing the other's copy), and this panel renders one
  genuinely new element `BookManualSearchComponent` has none of: a narrator line
  (`evidence.narrator`, informational only — see `AudiobookScorer`'s own moduledoc for why
  narrator evidence never gates accept/reject).

  Everything else — the async-search skeleton, `handle_async(:search, ...)`'s three clauses,
  `fetch_release/2`'s by-index resolution, `replace?/1` — is copied verbatim from
  `BookManualSearchComponent`, the identical "reuse the pattern, not the module" choice that
  component itself already documents against the movie/TV panel.

  Required assigns: `id`, `target` (a `%Cinder.Books.BookTarget{}`), `work` (the fully-preloaded
  `%Cinder.Books.Work{}` `Acquisition.Audiobooks.candidates/2` wants — editions/credits/series
  preloaded, e.g. from `Cinder.Books.get_work/1`). A `results:` assign (the raw
  `Acquisition.Audiobooks.candidates/2` map) is consumed directly and skips the async fetch —
  useful for tests, mirroring `BookManualSearchComponent`'s own `results:` escape hatch.

  Runs the search exactly once per mount: unlike the movie/TV panel, `/books/:id` has one fixed
  target per media kind and no season selector, so there is no context to diff and no reason to
  cancel/restart mid-panel.
  """
  use CinderWeb, :live_component

  import CinderWeb.LiveHelpers, only: [humanize_bytes: 1]

  require Logger

  alias Cinder.Acquisition.Audiobooks
  alias Cinder.Download

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      # A "grab" event racing an in-flight/failed search must never dereference an unset
      # `:results` — this is present from the very first render, never only once `handle_async`
      # or a preseed sets it, mirroring `BookManualSearchComponent`'s own `results: []` default.
      |> assign_new(:results, fn -> %{accepted: [], rejected: [], complete?: true} end)

    socket =
      cond do
        # Test / pre-seeded path: results supplied directly, skip the async fetch. Cancels any
        # in-flight search first — a caller that starts a connected search and then supplies
        # `results:` must not have the earlier task's late completion clobber the preseed.
        preseeded?(assigns) ->
          socket |> cancel_async(:search) |> assign(:state, :loaded)

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

  defp start_search(socket) do
    %{work: work, target: target} = socket.assigns

    start_async(socket, :search, fn ->
      Audiobooks.candidates(work,
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
  # not by title, for the same multi-tracker-dupe reason `BookManualSearchComponent` resolves by
  # index.
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
            <span :if={narrator_label(evidence.narrator)} class="text-xs text-base-content/60">
              {narrator_label(evidence.narrator)}
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

  # Best-effort, informational only — never a filter, never a sort key (`AudiobookScorer`'s own
  # "no narrator check" decision). Blank/unparsed narrator renders nothing at all, not an empty
  # "Narrated by" label.
  defp narrator_label(narrator) when narrator in [nil, ""], do: nil
  defp narrator_label(narrator), do: gettext("Narrated by %{narrator}", narrator: narrator)

  # One clause per `Cinder.Acquisition.AudiobookScorer.reasons/0` atom — kept in sync by
  # `test/cinder_web/components/audiobook_manual_search_component_test.exs`'s exhaustiveness
  # test, which iterates `AudiobookScorer.reasons/0` and fails if any atom falls through to the
  # fallback clause below. The same closed vocabulary `BookScorer.reasons/0` has, copied rather
  # than shared — see the moduledoc.
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
    Logger.warning("audiobook manual search: unrecognized rejection reason #{inspect(reason)}")
    gettext("rejected")
  end
end
