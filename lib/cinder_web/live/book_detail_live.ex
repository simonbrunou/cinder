defmodule CinderWeb.BookDetailLive do
  @moduledoc """
  Admin pipeline view for a book work at `/books/:id` — the books analogue of `/movies/:id`
  (deferred by B3b, claimed here). `:id` is the work's own id: a work independently monitors
  `:ebook` and `:audiobook`, so this renders one section per media kind, from whichever
  `%Cinder.Books.BookTarget{}` rows actually exist. A target only exists once
  `Cinder.Books.monitor_target/4` — the approval choke-point — has run, so a work reached here with
  a pending or denied request shows "Not yet approved" for that media kind, not a crash.

  The manual-search-and-Grab panel is offered for a `:monitored` `:ebook` or `:audiobook` target
  with no `BookGrab` already in flight (B7d) — an `:available` target instead offers "Find a
  better match", and a `:held` or already-downloading target renders read-only either way. Each
  kind renders through its own component (`CinderWeb.BookManualSearchComponent` /
  `CinderWeb.AudiobookManualSearchComponent` — different acquisition module, different candidate
  shape, see B7d's own plan §2 for why they stay separate rather than one component branching on
  kind). Every write reaches either `Cinder.Download.grab_book_target/3` or
  `Cinder.Books.set_target_language/2` (the ebook-only language picker
  `Cinder.Acquisition.BookScorer.check_language/2` scores against on the next search — see #404;
  an audiobook target has no language picker of its own, per B7d's own "no narrator/language UI
  beyond the ebook picker" scope note — its scorer already reads the release's own parsed tag);
  this module holds no `Repo` writes of its own.

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
  alias Cinder.Books.{Author, BookGrab, BookTarget, Work}
  alias Cinder.Catalog
  alias Cinder.Catalog.Profile
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
       |> assign(work: work, book_kinds: @book_kinds, searching?: nil, policy_previews: %{})
       |> assign_grabs()
       |> assign_blocklists()
       |> assign_author_policies()}
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

  # A live `Books.blocked_release_titles/1` call directly inside the render's `:for` (keyed off
  # `@work`) does not re-run on its own: `Phoenix.LiveView.Utils.assign/3` only marks `@work`
  # changed when the reloaded struct actually differs, and clearing a blocklist changes nothing
  # about the target/work rows themselves. An `@blocklists` assign — updated directly wherever
  # the blocklist actually changes — mirrors `@grabs`'s own pattern and gives the Clear-blocklist
  # button's visibility a value that genuinely changes when cleared.
  defp assign_blocklists(socket) do
    target_ids = Enum.map(socket.assigns.work.targets, & &1.id)
    blocklists = Books.blocked_release_titles_by_target_ids(target_ids)

    assign(socket, :blocklists, blocklists)
  end

  # A live `Books.author_policy/1` call directly inside the render's `:for` has the same staleness
  # problem `assign_blocklists/1` documents: an `@author_policies` assign, updated directly
  # wherever a policy actually changes, is what makes the `<select>`'s current value genuinely
  # change after a set/confirm.
  defp assign_author_policies(socket) do
    author_ids = socket.assigns.work |> credited_authors() |> Enum.map(& &1.id)
    policies = Books.author_policies_by_author_ids(author_ids)

    assign(socket, :author_policies, policies)
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

  # A `:held` target's manual re-entry: return it to `:monitored` for a human to pick a
  # different release. Deliberately does not clear the blocklist itself — see `Books.retry_target/1`.
  def handle_event("retry_target", %{"target_id" => raw_id}, socket) when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %BookTarget{work_id: work_id} = target <- Books.get_target(id),
         true <- work_id == socket.assigns.work.id do
      case Books.retry_target(target) do
        {:ok, _updated} ->
          {:noreply, reload(socket)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't retry this target. Try again."))}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  # Updates `@blocklists` directly rather than reloading `@work`: the button's visibility is
  # gated on `Map.get(@blocklists, target.id, [])`, a dedicated assign that genuinely changes
  # value when cleared — a bare `{:noreply, socket}`, or even reassigning `@work` to an
  # unaffected (structurally identical) struct, leaves LiveView's change tracking believing
  # nothing relevant changed (`Phoenix.LiveView.Utils.assign/3` only marks a key changed when the
  # new value actually differs), so the just-cleared button would stay on screen.
  def handle_event("clear_blocklist", %{"target_id" => raw_id}, socket)
      when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %BookTarget{work_id: work_id} = target <- Books.get_target(id),
         true <- work_id == socket.assigns.work.id do
      Books.clear_blocklist(target.id)
      {:noreply, assign(socket, :blocklists, Map.put(socket.assigns.blocklists, target.id, []))}
    else
      _invalid -> {:noreply, socket}
    end
  end

  # The author-policy `<select>`. `author_id` is checked against this work's own credited
  # authors (`credited_author/2`) — the cross-work-id guard #402/#407 fixed for retry/blocklist —
  # and `raw_policy` is matched against a fixed set of strings (`policy_from_param/1`), never
  # `String.to_atom/1` on a client value.
  #
  # `:specific` applies immediately (it only ever deletes a row — no preview needed, since turning
  # bulk automation off never removes an already-monitored target). `:future`/`:all` starts a
  # preview only when it actually differs from what is stored; re-selecting the active policy is
  # a no-op rather than a redundant re-preview.
  def handle_event("set_author_policy", %{"author_id" => raw_id, "policy" => raw_policy}, socket)
      when is_binary(raw_id) and is_binary(raw_policy) do
    with {id, ""} <- Integer.parse(raw_id),
         %Author{} = author <- credited_author(socket.assigns.work, id),
         policy when not is_nil(policy) <- policy_from_param(raw_policy),
         %BookTarget{} = ebook_target <- target_for(socket.assigns.work, :ebook) do
      {:noreply, apply_policy_selection(socket, author, policy, ebook_target)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  # Explicit "Preview again" for an already-active `:future`/`:all` policy — the escape hatch
  # `remaining_note/1`'s own copy promises ("run Preview again after confirming to see more") but
  # the `<select>` alone can't provide: a browser never fires `phx-change` when the user picks
  # the option already selected, and `apply_policy_selection/4`'s own differs-check would no-op a
  # forged repeat of the same value anyway. Reads the CURRENT stored policy, not a client-supplied
  # one, so this can never be used to preview a policy other than the one already confirmed.
  def handle_event("repreview_author_policy", %{"author_id" => raw_id}, socket)
      when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %Author{} = author <- credited_author(socket.assigns.work, id),
         policy when policy in [:future, :all] <- Map.get(socket.assigns.author_policies, id),
         %BookTarget{} = ebook_target <- target_for(socket.assigns.work, :ebook) do
      profile = Catalog.get_profile(ebook_target.profile_id)
      {:noreply, start_policy_preview(socket, author, policy, profile)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  # Confirms a held preview. `author_id` is only ever a key `start_policy_preview/4` itself put
  # into `@policy_previews`, scoped to this work's credited authors — the map membership check is
  # the trust boundary, not a re-derived `%Author{}`. A preview still `:loading`/`:error` (no
  # `:result` key yet) fails the match and is ignored rather than confirming nothing.
  def handle_event("confirm_author_policy", %{"author_id" => raw_id}, socket)
      when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %{policy: policy, profile: profile, result: %{eligible: eligible}} <-
           Map.get(socket.assigns.policy_previews, id) do
      {:ok, created_count} = Books.apply_author_policy(%Author{id: id}, policy, profile, eligible)

      socket =
        socket
        |> confirm_policy(id, policy)
        |> put_flash(:info, confirm_flash_text(created_count, length(eligible)))

      {:noreply, socket}
    else
      _invalid -> {:noreply, socket}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The manual-search panel forwards a chosen release back here (it owns no writes of its own).
  @impl true
  def handle_info({:manual_grab, :book, %BookTarget{id: target_id} = target, release}, socket) do
    outcome = Download.grab_book_target(target, release, replace: target.status == :available)
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

  # A second admin tab (on this work, or any other work sharing the credited author) changing
  # the same author's policy — keeps `@author_policies` (and therefore the `<select>`) current
  # without a full remount. Scoped to authors this work actually credits, mirroring `@grabs`'s
  # own `Map.has_key?/2` guard.
  def handle_info({:book_author_policy_updated, author_id}, socket) do
    if Map.has_key?(socket.assigns.author_policies, author_id) do
      policies =
        Map.put(socket.assigns.author_policies, author_id, Books.author_policy(author_id))

      {:noreply, assign(socket, :author_policies, policies)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:preview_author_policy, author_id}, {:ok, {:ok, result}}, socket) do
    {:noreply,
     update_policy_preview(socket, author_id, &Map.merge(&1, %{state: :loaded, result: result}))}
  end

  def handle_async({:preview_author_policy, author_id}, {:ok, {:error, _reason}}, socket) do
    {:noreply, update_policy_preview(socket, author_id, &Map.put(&1, :state, :error))}
  end

  def handle_async({:preview_author_policy, author_id}, {:exit, _reason}, socket) do
    {:noreply, update_policy_preview(socket, author_id, &Map.put(&1, :state, :error))}
  end

  # Re-read the work fresh from the DB — used after every write and after a
  # `:book_target_updated` broadcast, so both this target's status/hold_reason and its sibling
  # target's are current, and the in-flight grab map (a target's grab is deleted the moment its
  # target leaves `:monitored`) stays honest.
  defp reload(socket) do
    case Books.get_work(socket.assigns.work.id) do
      nil -> socket
      work -> socket |> assign(:work, work) |> assign_grabs() |> assign_blocklists()
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

  defp searchable?(%BookTarget{media_kind: :audiobook, status: :monitored}, nil), do: true
  defp searchable?(%BookTarget{media_kind: :ebook, status: :monitored}, nil), do: true
  defp searchable?(_target, _grab), do: false

  defp replaceable?(%BookTarget{media_kind: :audiobook, status: :available}, nil), do: true
  defp replaceable?(%BookTarget{media_kind: :ebook, status: :available}, nil), do: true
  defp replaceable?(_target, _grab), do: false

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

  defp credited_authors(work), do: work.credits |> Enum.map(& &1.author) |> Enum.uniq_by(& &1.id)

  defp credited_author(work, id), do: work |> credited_authors() |> Enum.find(&(&1.id == id))

  defp policy_from_param("specific"), do: :specific
  defp policy_from_param("future"), do: :future
  defp policy_from_param("all"), do: :all
  defp policy_from_param(_other), do: nil

  defp apply_policy_selection(socket, %Author{id: id} = author, :specific, _ebook_target) do
    {:ok, nil} = Books.set_author_policy(author, :specific, nil)

    socket
    |> assign(:author_policies, Map.put(socket.assigns.author_policies, id, :specific))
    |> clear_policy_preview(id)
  end

  defp apply_policy_selection(socket, %Author{id: id} = author, policy, ebook_target) do
    if Map.get(socket.assigns.author_policies, id, :specific) == policy do
      socket
    else
      start_policy_preview(socket, author, policy, Catalog.get_profile(ebook_target.profile_id))
    end
  end

  defp start_policy_preview(socket, %Author{id: id} = author, policy, %Profile{} = profile) do
    preview = %{state: :loading, policy: policy, profile: profile}

    socket
    |> assign(:policy_previews, Map.put(socket.assigns.policy_previews, id, preview))
    |> start_async({:preview_author_policy, id}, fn ->
      Books.preview_author_policy(author, policy)
    end)
  end

  # No profile to arm a new target with (should not happen — every rendered ebook target already
  # has one, see `Cinder.Books.monitor_target/4`) — fail closed rather than preview with nothing
  # to confirm against.
  defp start_policy_preview(socket, _author, _policy, nil), do: socket

  defp update_policy_preview(socket, author_id, fun) do
    case Map.get(socket.assigns.policy_previews, author_id) do
      nil ->
        socket

      preview ->
        assign(
          socket,
          :policy_previews,
          Map.put(socket.assigns.policy_previews, author_id, fun.(preview))
        )
    end
  end

  defp clear_policy_preview(socket, author_id),
    do: assign(socket, :policy_previews, Map.delete(socket.assigns.policy_previews, author_id))

  defp confirm_policy(socket, author_id, policy) do
    socket
    |> assign(:author_policies, Map.put(socket.assigns.author_policies, author_id, policy))
    |> clear_policy_preview(author_id)
  end

  defp policy_options do
    [
      {gettext("Selected works"), "specific"},
      {gettext("Future works"), "future"},
      {gettext("All works"), "all"}
    ]
  end

  defp policy_param(:specific), do: "specific"
  defp policy_param(:future), do: "future"
  defp policy_param(:all), do: "all"

  defp repreviewable?(author_id, author_policies, policy_previews) do
    Map.get(author_policies, author_id, :specific) in [:future, :all] and
      not loading?(Map.get(policy_previews, author_id))
  end

  defp loading?(%{state: :loading}), do: true
  defp loading?(_other), do: false

  defp preview_summary_text(0), do: gettext("Nothing new to monitor.")

  defp preview_summary_text(count),
    do:
      ngettext(
        "%{count} new eBook would be monitored.",
        "%{count} new eBooks would be monitored.",
        count
      )

  defp ambiguous_note(count),
    do:
      ngettext(
        "%{count} work could not be identified: never monitored automatically.",
        "%{count} works could not be identified: never monitored automatically.",
        count
      )

  defp remaining_note(remaining) do
    examined = Books.max_bibliography_candidates()

    gettext(
      "Showing %{examined} of %{total} not-yet-monitored works; run Preview again after confirming to see more.",
      examined: examined,
      total: examined + remaining
    )
  end

  # `created_count` can be lower than `previewed_count` when a candidate was independently
  # claimed (a direct approval, a different admin's confirm, a refresher tick) in the gap between
  # preview and this confirm (see `Books.apply_author_policy/4`) — say so rather than reporting a
  # number the operator has no way to reconcile against what the preview promised.
  defp confirm_flash_text(created_count, previewed_count) when created_count == previewed_count do
    ngettext(
      "%{count} eBook is now monitored.",
      "%{count} eBooks are now monitored.",
      created_count
    )
  end

  defp confirm_flash_text(created_count, previewed_count) do
    gettext(
      "%{created} of %{previewed} previewed works are now monitored; the rest were already claimed by another action in the meantime.",
      created: created_count,
      previewed: previewed_count
    )
  end

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

      <div
        :if={target_for(@work, :ebook)}
        id="book-author-policies"
        class="mt-4 flex flex-col gap-4"
      >
        <div :for={author <- credited_authors(@work)} id={"author-policy-#{author.id}"}>
          <form id={"author-policy-form-#{author.id}"} phx-change="set_author_policy" class="w-64">
            <input type="hidden" name="author_id" value={author.id} />
            <.input
              type="select"
              name="policy"
              label={gettext("%{name}'s monitoring", name: author.name)}
              value={policy_param(Map.get(@author_policies, author.id, :specific))}
              options={policy_options()}
              class="select select-sm w-full"
            />
          </form>

          <.button
            :if={repreviewable?(author.id, @author_policies, @policy_previews)}
            type="button"
            variant="ghost"
            size="sm"
            phx-click="repreview_author_policy"
            phx-value-author_id={author.id}
          >
            {gettext("Preview again")}
          </.button>

          <div :if={preview = Map.get(@policy_previews, author.id)} class="mt-1 text-sm">
            <p :if={preview.state == :loading} class="text-base-content/60">
              {gettext("Checking the author's bibliography…")}
            </p>

            <p :if={preview.state == :error} class="text-error">
              {gettext("Couldn't preview this policy. Try again.")}
            </p>

            <div :if={preview.state == :loaded} class="flex flex-col items-start gap-1">
              <p>{preview_summary_text(length(preview.result.eligible))}</p>
              <p :if={preview.result.ambiguous_count > 0} class="text-base-content/60">
                {ambiguous_note(preview.result.ambiguous_count)}
              </p>
              <p :if={preview.result.remaining > 0} class="text-base-content/60">
                {remaining_note(preview.result.remaining)}
              </p>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="confirm_author_policy"
                phx-value-author_id={author.id}
              >
                {gettext("Confirm")}
              </.button>
            </div>
          </div>
        </div>
      </div>

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
              :if={target.status == :held}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="retry_target"
              phx-value-target_id={target.id}
            >
              {gettext("Retry")}
            </.button>

            <.button
              :if={target.status == :held and Map.get(@blocklists, target.id, []) != []}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="clear_blocklist"
              phx-value-target_id={target.id}
            >
              {gettext("Clear blocklist")}
            </.button>

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

            <.button
              :if={replaceable?(target, grab)}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="manual_search"
              phx-value-target_id={target.id}
            >
              {gettext("Find a better match")}
            </.button>

            <.live_component
              :if={@searching? == target.id and target.media_kind == :ebook}
              module={CinderWeb.BookManualSearchComponent}
              id={"ms-book-#{target.id}"}
              target={target}
              work={@work}
            />

            <.live_component
              :if={@searching? == target.id and target.media_kind == :audiobook}
              module={CinderWeb.AudiobookManualSearchComponent}
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
