defmodule CinderWeb.BookDetailLive do
  @moduledoc """
  Admin pipeline view for a book work at `/books/:id` — the books analogue of `/movies/:id`
  (deferred by B3b, claimed here). `:id` is the work's own id: a work independently monitors
  `:ebook` and `:audiobook`, so this renders one section per media kind, from whichever
  `%Cinder.Books.BookTarget{}` rows actually exist. A target only exists once
  `Cinder.Books.monitor_target/4` — the approval choke-point — has run, so a work reached here with
  a pending or denied request shows "Not yet approved" for that media kind, not a crash.

  The manual-search-and-Grab panel is offered only for a `:monitored` `:ebook` target with no
  `BookGrab` already in flight (an `:audiobook` target, an `:available`/`:held` target, and a
  target already downloading all render read-only — see the B4c plan). Every write reaches either
  `Cinder.Download.grab_book_target/2` or `Cinder.Books.set_target_language/2` (the ebook-only
  language picker `Cinder.Acquisition.BookScorer.check_language/2` scores against on the next
  search — see #404); this module holds no `Repo` writes of its own.

  Subscribes to `Cinder.Books.subscribe_targets/0` for `{:book_target_updated, target}`
  (terminal status transitions and a language change alike), `{:book_grab_updated, grab}` (live
  download progress), and `{:book_grab_deleted, target_id}` (the corrective for a grab deletion
  this view's own `reload/1` raced and lost — see `Cinder.Books.Grabs.delete/1`), all broadcast
  on the same `book_targets` PubSub topic.
  """
  use CinderWeb, :live_view

  import CinderWeb.BookComponents, only: [book_state_badge: 1]
  import CinderWeb.LiveHelpers, only: [book_badge_state: 2]

  alias Cinder.Acquisition.Parser
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget, Work}
  alias Cinder.Download
  alias Cinder.LibraryKind

  @book_kinds LibraryKind.books()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {id, ""} <- Integer.parse(id),
         %Work{} = work <- Books.get_work(id) do
      if connected?(socket), do: Books.subscribe_targets()

      {:ok,
       socket
       |> assign(work: work, book_kinds: @book_kinds, searching?: nil)
       |> assign_grabs()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That book couldn't be found."))
         |> push_navigate(to: ~p"/requests")}
    end
  end

  defp assign_grabs(socket) do
    grabs =
      Map.new(socket.assigns.work.targets, fn target ->
        {target.id, Books.Grabs.for_target(target.id)}
      end)

    assign(socket, :grabs, grabs)
  end

  @impl true
  def handle_event("manual_search", %{"target_id" => raw_id}, socket) when is_binary(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        open = if socket.assigns.searching? == id, do: nil, else: id
        {:noreply, assign(socket, :searching?, open)}

      _invalid ->
        {:noreply, socket}
    end
  end

  # An ebook target's own language preference, set from this page independent of any search —
  # audiobook is guarded out: `searchable?/2` never offers a search for one, so a picker there
  # would be a control with no observable effect. `raw_language` is always a string (a `<select>`
  # posts its blank option as `""`, not an absent key), but guarded anyway per #402's audit —
  # a forged non-string payload falls through to the catch-all instead of reaching `==/2` on a
  # shape `Books.set_target_language/2` never expected.
  def handle_event("set_language", %{"target_id" => raw_id, "language" => raw_language}, socket)
      when is_binary(raw_id) and is_binary(raw_language) do
    language = if raw_language == "", do: nil, else: raw_language

    with {id, ""} <- Integer.parse(raw_id),
         %BookTarget{media_kind: :ebook, work_id: work_id} = target <- Books.get_target(id),
         true <- work_id == socket.assigns.work.id do
      Books.set_target_language(target, language)
    end

    {:noreply, socket}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The manual-search panel forwards a chosen release back here (it owns no writes of its own).
  @impl true
  def handle_info({:manual_grab, :book, %BookTarget{id: target_id} = target, release}, socket) do
    outcome = Download.grab_book_target(target, release)
    socket = socket |> assign(:searching?, nil) |> reload()
    {level, msg} = book_grab_flash(outcome, socket, target_id)
    {:noreply, put_flash(socket, level, msg)}
  end

  def handle_info(
        {:book_target_updated, %{work_id: work_id}},
        %{assigns: %{work: %{id: work_id}}} = socket
      ) do
    {:noreply, reload(socket)}
  end

  def handle_info({:book_target_updated, _target}, socket), do: {:noreply, socket}

  def handle_info({:book_grab_updated, %BookGrab{book_target_id: target_id} = grab}, socket) do
    if Map.has_key?(socket.assigns.grabs, target_id) do
      {:noreply, assign(socket, :grabs, Map.put(socket.assigns.grabs, target_id, grab))}
    else
      {:noreply, socket}
    end
  end

  # The corrective message for the race `Cinder.Books.Grabs.delete/1` documents: this target's
  # own terminal `:book_target_updated` broadcast can be re-read (via `reload/1` above) before
  # the grab row backing it is actually deleted, repopulating `@grabs` with a grab about to
  # vanish. Dropping it here is idempotent — `Map.delete/2` on an absent key is a no-op — so it is
  # safe whether or not this view lost that earlier race.
  def handle_info({:book_grab_deleted, target_id}, socket) do
    {:noreply, assign(socket, :grabs, Map.delete(socket.assigns.grabs, target_id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Re-read the work fresh from the DB — used after every write and after a
  # `:book_target_updated` broadcast, so both this target's status/hold_reason and its sibling
  # target's are current, and the in-flight grab map (a target's grab is deleted the moment its
  # target leaves `:monitored`) stays honest.
  defp reload(socket) do
    case Books.get_work(socket.assigns.work.id) do
      nil -> socket
      work -> socket |> assign(:work, work) |> assign_grabs()
    end
  end

  defp book_grab_flash({:ok, %BookGrab{}}, _socket, _target_id),
    do: {:info, gettext("Grabbing the selected release…")}

  defp book_grab_flash({:error, :download_intent_busy}, _socket, _target_id),
    do: {:error, gettext("This target already has a download in progress.")}

  # Every other error atom (`:unsupported_media_kind`, `:bad_torrent` and the rest of
  # `Cinder.Download`'s permanent-submission-error set, a raw `%Ecto.Changeset{}`) is read back
  # from the target's own post-grab state rather than pattern-matched by atom: `grab_book_target/2`
  # already parks a permanently rejected submission `:held` with an exact reason before returning,
  # so re-reading the fresh `hold_reason` off the just-reloaded work renders the real reason without
  # this module needing to import `Cinder.Download`'s private error-atom list.
  defp book_grab_flash({:error, _reason}, socket, target_id) do
    case Enum.find(socket.assigns.work.targets, &(&1.id == target_id)) do
      %BookTarget{status: :held, hold_reason: reason} when is_binary(reason) ->
        {:error, reason}

      _not_held ->
        {:error, gettext("Couldn't submit this release. Try again.")}
    end
  end

  defp target_for(work, kind), do: Enum.find(work.targets, &(&1.media_kind == kind))

  defp searchable?(%BookTarget{media_kind: :ebook, status: :monitored}, nil), do: true
  defp searchable?(_target, _grab), do: false

  defp grab_status(%BookGrab{content_path: nil}), do: :downloading
  defp grab_status(%BookGrab{}), do: :downloaded

  defp kind_label(:ebook), do: gettext("eBook")
  defp kind_label(:audiobook), do: gettext("Audiobook")

  defp contributor_names(work), do: Enum.map_join(work.credits, ", ", & &1.author.name)

  # Sourced from `Parser.language_tags/0` rather than a hand-written list, so a language the
  # picker offers is always one `BookScorer.tag_for/1` can actually resolve — a free-text code
  # field would let an admin pick a value the scorer can never match, with no obvious reason why.
  # Labels are the tag titlecased ("FRENCH" -> "French"), not gettext-translated: these are
  # language names, not UI copy, and every locale already renders them in English here.
  defp language_options do
    [{gettext("No preference"), ""} | language_choices()]
  end

  defp language_choices do
    Parser.language_tags()
    |> Enum.map(fn {code, tag} -> {titlecase(tag), code} end)
    |> Enum.sort()
  end

  defp titlecase(tag), do: tag |> String.downcase() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.link navigate={~p"/requests"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Requests")}
      </.link>

      <.header>
        {@work.title}
        <span :if={@work.first_published_on} class="font-normal text-base-content/70">
          ({@work.first_published_on.year})
        </span>
      </.header>

      <p :if={@work.credits != []} class="text-sm text-base-content/70">
        {contributor_names(@work)}
      </p>

      <div class="mt-6 flex flex-col gap-6">
        <section :for={kind <- @book_kinds} aria-labelledby={"book-target-#{kind}-heading"}>
          <h2 id={"book-target-#{kind}-heading"} class="mb-2 text-lg font-semibold">
            {kind_label(kind)}
          </h2>

          <% target = target_for(@work, kind) %>

          <p :if={is_nil(target)} class="text-sm text-base-content/60">
            {gettext("Not yet approved.")}
          </p>

          <div :if={target} id={"book-target-#{kind}"} class="flex flex-col items-start gap-2">
            <.book_state_badge
              id={"book-target-state-#{kind}"}
              kind={kind}
              state={book_badge_state(nil, target.status)}
            />

            <p
              :if={target.status == :held and target.hold_reason}
              id={"book-target-hold-reason-#{kind}"}
              class="text-sm text-warning"
            >
              {target.hold_reason}
            </p>

            <% grab = Map.get(@grabs, target.id) %>

            <.status_badge
              :if={grab}
              kind={:grab}
              status={grab_status(grab)}
              progress={grab.download_progress}
              speed={grab.download_speed}
              eta={grab.download_eta}
            />

            <form
              :if={kind == :ebook}
              id={"book-target-language-#{kind}"}
              phx-change="set_language"
              class="w-48"
            >
              <input type="hidden" name="target_id" value={target.id} />
              <.input
                type="select"
                name="language"
                label={gettext("Language")}
                value={target.preferred_language || ""}
                options={language_options()}
                class="select select-sm w-full"
              />
            </form>

            <.button
              :if={searchable?(target, grab)}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="manual_search"
              phx-value-target_id={target.id}
            >
              {gettext("Search for a release")}
            </.button>

            <.live_component
              :if={@searching? == target.id}
              module={CinderWeb.BookManualSearchComponent}
              id={"ms-book-#{target.id}"}
              target={target}
              work={@work}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
