defmodule CinderWeb.ManualSearchComponent do
  @moduledoc """
  Interactive manual-search panel, shared by the movie and TV views. Queries the indexer
  asynchronously and lists every release with its scorer verdict, letting the user grab any one
  (overriding the band/blocklist, and for a movie found by IMDb id the title guard: a release
  naming none of its titles is flagged "title doesn't match"). Grabs are forwarded to the parent
  LiveView, which owns the Catalog writes, via
  `send(self(), {:manual_grab, mode, target, release})`. For an
  `:available` movie target a "Replace current file?" confirm gates the grab. An empty result
  shows "No releases found." TV season searches include wanted and already-available episodes,
  so fully imported seasons can open the panel for an operator-chosen upgrade.

  The rows are the sweep's own release judge (`Cinder.Acquisition.ReleaseJudge`), so the panel
  renders what automatic selection decided rather than re-deriving it. Every row carries a
  language badge, untagged included: untagged means English by scene convention and is precisely
  the row an audio pick decides. A release the sweep rejects on language is badged `warning`
  (icon + `sr-only` text, not colour alone) and ranked below one that satisfies the pick, but
  never hidden: the panel is the override surface.

  Required assigns: `id`, `mode` (`:movie | :tv`), `target` (the `%Movie{}` or `%Series{}`), plus
  `season_number` for `:tv`. A `results:` assign (a list of rows, each a map with `release`,
  `verdict` and `audio`, as `ReleaseJudge` builds them) is consumed directly and skips the async
  fetch — useful for tests.
  """
  use CinderWeb, :live_component

  alias Cinder.{Acquisition, Catalog, Settings}
  alias Cinder.Acquisition.{AnimePreferences, HouseholdPolicy, Language}

  @impl true
  def update(assigns, socket) do
    search_context = search_context(assigns)
    context_changed? = search_context_changed?(socket, search_context)

    socket =
      socket
      |> assign(assigns)
      |> assign(:search_context, search_context)
      |> assign_new(:confirming, fn -> nil end)
      |> maybe_cancel_stale_search(context_changed?)

    socket =
      cond do
        # Test / pre-seeded path: results supplied directly, skip the async fetch.
        preseeded?(assigns) ->
          assign(socket, :state, :loaded)

        # A new target/profile/policy context must never consume an old result list.
        context_changed? ->
          restart_search(socket)

        # Already initialised for this context — keep state/results/confirming as they are.
        not is_nil(socket.assigns[:state]) ->
          socket

        # First render, connected: run the search off-process.
        connected?(socket) ->
          socket |> assign(state: :loading, results: []) |> start_search()

        # First render, not yet connected (dead render): placeholder until the live mount.
        true ->
          assign(socket, state: :loading, results: [])
      end

    {:ok, socket}
  end

  defp preseeded?(assigns), do: Map.has_key?(assigns, :results) and not is_nil(assigns[:results])

  defp search_context(assigns) do
    target = assigns.target
    profile = Catalog.media_profile_summary(target).effective

    policy =
      if profile == :anime,
        do: AnimePreferences.resolve(target, Settings.anime_defaults()),
        else: nil

    {assigns.mode, target.__struct__, target.id, assigns[:season_number], profile, policy,
     audio_pick(profile, target)}
  end

  # What the judge's language stage reads from the title: the resolved audio target (nil when the
  # filter is off: anime, which resolves audio through `AnimePreferences` instead; "any";
  # "original" on a title with no TMDB original language) and whether the pick is strict.
  #
  # Held RESOLVED so both inputs — the pick and, for "original", the title's TMDB
  # `original_language` — sit behind one context element: a metadata refresh that moves the target
  # restarts the search rather than leaving the old ordering and badges behind. It changes iff the
  # language stage's outcome could, and no more: "french" ⇄ "dual" resolve alike and stay a
  # no-op, while "original" ⇄ "french" on a French title re-judges, because a soft pick keeps
  # untagged releases and falls back where a strict one drops them.
  defp audio_pick(:anime, _target), do: nil

  defp audio_pick(_profile, target) do
    {Language.target(target.preferred_language, target.original_language),
     Language.strict?(target.preferred_language)}
  end

  defp search_context_changed?(socket, current) do
    previous = socket.assigns[:search_context] || previous_search_context(socket.assigns)
    not is_nil(previous) and previous != current
  end

  defp previous_search_context(%{mode: _mode, target: _target} = assigns),
    do: search_context(assigns)

  defp previous_search_context(_assigns), do: nil

  defp maybe_cancel_stale_search(socket, true),
    do: socket |> cancel_async(:search) |> assign(:confirming, nil)

  defp maybe_cancel_stale_search(socket, false), do: socket

  defp restart_search(socket) do
    socket = assign(socket, state: :loading, results: [])
    if connected?(socket), do: start_search(socket), else: socket
  end

  defp start_search(socket) do
    %{mode: mode, target: target} = socket.assigns
    season = socket.assigns[:season_number]
    # The sweep's own household policy, so the panel's verdicts and order are the sweep's.
    opts = HouseholdPolicy.for_target(target)
    profile = Catalog.media_profile_summary(target).effective

    start_async(socket, :search, fn ->
      search(profile, mode, target, season, opts)
    end)
  end

  defp search(:anime, :movie, target, _season, opts) do
    with {:ok, policy} <- AnimePreferences.resolve(target, Settings.anime_defaults()),
         {:ok, pairs} <-
           Acquisition.list_anime_movie_releases(
             target.imdb_id,
             Catalog.movie_acquisition_context(target),
             opts ++ [anime_policy: policy]
           ),
         do: {:ok, anime_rows(pairs)}
  end

  defp search(:anime, :tv, target, season, opts) do
    with {:ok, policy} <- AnimePreferences.resolve(target, Settings.anime_defaults()),
         {:ok, pairs} <-
           Acquisition.list_anime_episode_releases(
             Catalog.anime_series_acquisition_context(target),
             manual_episode_ids(target, season),
             opts ++ [anime_policy: policy]
           ),
         do: {:ok, anime_rows(pairs)}
  end

  defp search(:standard, :movie, target, _season, opts) do
    with {:ok, judged} <-
           Acquisition.judge_movie(
             target.imdb_id,
             Catalog.movie_acquisition_context(target),
             opts
           ),
         do: {:ok, judged.rows}
  end

  defp search(:standard, :tv, target, season, opts) do
    episodes = Catalog.manual_search_episodes(target.id, season)

    numbering =
      target
      |> Catalog.anime_series_acquisition_context()
      |> Acquisition.standard_tv_numbering(episodes, MapSet.new([season]))

    # Whole-season packs are verdict-banded per episode (k×band, like the sweep);
    # pass the season's wanted count so a pack isn't judged as one episode's size.
    opts = opts ++ [pack_episode_count: max(length(episodes), 1)]

    with {:ok, judged} <- Acquisition.judge_season(target, season, numbering, opts),
         do: {:ok, judged.rows}
  end

  # The anime searches don't go through the release judge yet (#775). Anime resolves audio through
  # its policy, never the name's tag, so no row carries a language fact.
  defp anime_rows(pairs),
    do:
      Enum.map(pairs, fn {release, verdict} ->
        %{release: release, verdict: verdict, audio: nil}
      end)

  defp manual_episode_ids(series, season_number) do
    series.id
    |> Catalog.manual_search_episodes(season_number)
    |> Enum.map(fn episode ->
      episode.id
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, results}}, socket),
    do: {:noreply, assign(socket, state: :loaded, results: results)}

  def handle_async(:search, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, :state, :error)}

  def handle_async(:search, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :state, :error)}

  @impl true
  def handle_event("ask_replace", %{"index" => index}, socket),
    do: {:noreply, assign(socket, :confirming, index)}

  def handle_event("dismiss_replace", _params, socket),
    do: {:noreply, assign(socket, :confirming, nil)}

  def handle_event("grab", params, socket) do
    # Resolve by list index, not title: multi-tracker Prowlarr dupes can share an identical
    # title, so a title match could grab the wrong release (different protocol/size/download_url).
    # The confirm button carries no phx-value, so fall back to the pending index in @confirming.
    case fetch_row(socket.assigns.results, params["index"] || socket.assigns.confirming) do
      %{release: release} ->
        send(self(), {:manual_grab, socket.assigns.mode, socket.assigns.target, release})

      nil ->
        :noop
    end

    {:noreply, assign(socket, :confirming, nil)}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # phx-value-index arrives as a string; resolve it to the row by position.
  defp fetch_row(results, index) when is_binary(index) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 -> Enum.at(results, i)
      _ -> nil
    end
  end

  defp fetch_row(_results, _index), do: nil

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
      <p :if={@state == :loaded and @results == []} class="text-sm">
        {gettext("No releases found.")}
      </p>

      <ul :if={@state == :loaded and @results != []} class="space-y-1">
        <li
          :for={{%{release: release, verdict: verdict} = row, index} <- Enum.with_index(@results)}
          class="flex flex-wrap items-center gap-2 text-sm"
        >
          <span class="min-w-0 flex-1 truncate" title={release.title}>{release.title}</span>
          <span class="badge badge-xs">{release.resolution || gettext("?")}</span>
          <.language_badge language={release.language} state={row.audio} />
          <span :if={verdict != :ok} class="text-xs text-warning">{verdict_reason(verdict)}</span>
          <.button
            :if={grabbable?(verdict)}
            type="button"
            size="xs"
            variant="ghost"
            phx-target={@myself}
            phx-click={grab_click(@mode, @target, release)}
            phx-value-index={index}
            phx-disable-with={gettext("Grabbing…")}
          >
            {gettext("Grab")}
          </.button>
        </li>
      </ul>

      <.confirm_action
        :if={@confirming}
        id={"#{@id}-replace-confirm"}
        on_confirm="grab"
        on_cancel="dismiss_replace"
        variant="warning"
        phx-target={@myself}
        confirm_label={gettext("Replace file")}
      >
        <:caveat>
          {gettext("Replace the current file for this movie with the selected release?")}
        </:caveat>
      </.confirm_action>
    </div>
    """
  end

  attr :language, :string, default: nil
  attr :state, :atom, default: nil

  defp language_badge(assigns) do
    assigns = assign(assigns, :explanation, language_explanation(assigns.state))

    ~H"""
    <span
      class={[
        "badge badge-xs gap-1",
        if(@state == :mismatch, do: "badge-warning", else: "badge-ghost")
      ]}
      title={@explanation}
    >
      <.icon :if={@state == :mismatch} name="hero-exclamation-triangle-mini" class="size-3" />
      {release_language_label(@language)}
      <span :if={@explanation} class="sr-only">{@explanation}</span>
    </span>
    """
  end

  # An untagged release is English audio by scene convention (see `Cinder.Acquisition.Language`),
  # so "no badge" was never "no information" — it is exactly the row an audio pick decides. Say it.
  defp release_language_label(language) when language in [nil, ""], do: gettext("untagged")
  defp release_language_label(language), do: language

  # The row's `audio` is the release judge's language fact (`Cinder.Acquisition.ReleaseJudge`):
  # the panel states it, never re-derives it. Re-deriving it is how this badge got it wrong twice.
  defp language_explanation(:match), do: gettext("Matches this title's audio pick")

  defp language_explanation(:assumed),
    do: gettext("Untagged: assumed to be the original audio, ranked below a tagged match")

  defp language_explanation(:mismatch), do: gettext("Doesn't match this title's audio pick")
  defp language_explanation(nil), do: nil

  # An :available movie grab routes through the replace-confirm; everything else grabs directly.
  defp grab_click(:movie, %{status: :available}, _release), do: "ask_replace"
  defp grab_click(_mode, _target, _release), do: "grab"

  # Protocol and stable-ID safety cannot be overridden. Policy/quality verdicts can.
  defp grabbable?({:rejected, :wrong_protocol}), do: false
  defp grabbable?({:rejected, :unsafe_anime_mapping}), do: false
  defp grabbable?(_), do: true

  defp verdict_reason({:rejected, :out_of_band}), do: gettext("outside size band")
  defp verdict_reason({:rejected, :blocklisted}), do: gettext("blocklisted")
  defp verdict_reason({:rejected, :blocked_term}), do: gettext("contains a blocked term")
  defp verdict_reason({:rejected, :wrong_resolution}), do: gettext("resolution not preferred")
  defp verdict_reason({:rejected, :wrong_source}), do: gettext("source not preferred")
  defp verdict_reason({:rejected, :wrong_protocol}), do: gettext("no client for protocol")
  defp verdict_reason({:rejected, :blocked_anime_group}), do: gettext("blocked anime group")
  defp verdict_reason({:rejected, :contradictory_audio}), do: gettext("contradictory audio")

  defp verdict_reason({:rejected, :contradictory_subtitles}),
    do: gettext("contradictory subtitles")

  defp verdict_reason({:rejected, :awaiting_preferred_group}),
    do: gettext("awaiting preferred group")

  defp verdict_reason({:rejected, :publication_time_required}),
    do: gettext("publication time required")

  defp verdict_reason({:rejected, :unsafe_anime_mapping}),
    do: gettext("stable episode mapping required")

  defp verdict_reason({:rejected, :conflicting_standard_numbering}),
    do: gettext("conflicting episode numbering")

  defp verdict_reason({:rejected, :title_mismatch}), do: gettext("title doesn't match")

  defp verdict_reason(_), do: ""
end
