defmodule CinderWeb.ManualSearchComponent do
  @moduledoc """
  Interactive manual-search panel, shared by the movie and TV views. Queries the indexer
  asynchronously and lists every release with its scorer verdict, letting the user grab any one
  (overriding the band/blocklist for selection). Grabs are forwarded to the parent LiveView, which
  owns the Catalog writes, via `send(self(), {:manual_grab, mode, target, release})`. For an
  `:available` movie target a "Replace current file?" confirm gates the grab. An empty result
  shows "No releases found." TV season searches include wanted and already-available episodes,
  so fully imported seasons can open the panel for an operator-chosen upgrade.

  Every row carries a language badge — untagged included, since untagged means English by scene
  convention and is precisely the row an audio pick decides. A release the sweep would actually
  reject on language is badged `warning` (icon + `sr-only` text, not colour alone) and ranked
  below one that satisfies the pick, but never hidden: the panel is the override surface. Flagging
  deliberately mirrors what the sweep does rather than a bare tag comparison — see
  `language_state/2` for the untagged-under-a-soft-pick case, and `audio_pick/2` for the three
  cases where it stays silent.

  Required assigns: `id`, `mode` (`:movie | :tv`), `target` (the `%Movie{}` or `%Series{}`), plus
  `season_number` for `:tv`. A `results:` assign (a list of `{release, verdict}` tuples) is
  consumed directly and skips the async fetch — useful for tests.
  """
  use CinderWeb, :live_component

  alias Cinder.{Acquisition, Catalog, Download, Settings}
  alias Cinder.Acquisition.{AnimePreferences, Language}

  @impl true
  def update(assigns, socket) do
    search_context = search_context(assigns)
    context_changed? = search_context_changed?(socket, search_context)

    socket =
      socket
      |> assign(assigns)
      |> assign(:search_context, search_context)
      |> assign(:audio_pick, context_audio_pick(search_context))
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

  # What rows are flagged and ranked against: `{strict?, target}`, or nil for no flagging at all.
  #
  # Held RESOLVED so both inputs — the pick and, for "original", the title's TMDB
  # `original_language` — sit behind one context element: a metadata refresh that moves the target
  # restarts the search instead of leaving the old ordering under freshly flipped badges. Carrying
  # `strict?/1` rather than the raw pick keeps "french" ⇄ "dual" (same target, same strictness) a
  # no-op instead of a needless re-query.
  #
  # nil in three cases, each one where flagging would out-claim the sweep:
  #   - anime, which resolves audio through `AnimePreferences` (its own `:contradictory_audio`
  #     verdict, and it deliberately never name-tag filters) — `policy` already carries the pick;
  #   - "any", or "original" on a title with no TMDB original language — the filter is off;
  #   - an original language outside the parser's tag registry (Icelandic, Catalan, Tagalog…).
  #     `Language.target/2` hands those back unmapped, so `satisfies_lang?/2` can never be true and
  #     EVERY row would badge as a mismatch — while `language_pool/4` falls back to the unfiltered
  #     candidates and `rank_key/2` ties, i.e. the sweep has no opinion whatsoever.
  # The badge itself still renders in all three; only the flagging goes quiet.
  defp audio_pick(:anime, _target), do: nil

  defp audio_pick(_profile, target) do
    resolved = Language.target(target.preferred_language, target.original_language)

    if Language.known?(resolved),
      do: {Language.strict?(target.preferred_language), resolved},
      else: nil
  end

  defp context_audio_pick(search_context), do: elem(search_context, 6)

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
    opts = search_opts(mode, target)
    profile = Catalog.media_profile_summary(target).effective

    start_async(socket, :search, fn ->
      search(profile, mode, target, season, opts)
    end)
  end

  defp search(:anime, :movie, target, _season, opts) do
    with {:ok, policy} <- AnimePreferences.resolve(target, Settings.anime_defaults()) do
      Acquisition.list_anime_movie_releases(
        target.imdb_id,
        Catalog.anime_movie_acquisition_context(target),
        opts ++ AnimePreferences.selection_opts(policy)
      )
    end
  end

  defp search(:anime, :tv, target, season, opts) do
    with {:ok, policy} <- AnimePreferences.resolve(target, Settings.anime_defaults()) do
      Acquisition.list_anime_episode_releases(
        Catalog.anime_series_acquisition_context(target),
        manual_episode_ids(target, season),
        opts ++ AnimePreferences.selection_opts(policy)
      )
    end
  end

  defp search(:standard, :movie, %{imdb_id: imdb_id} = target, _season, opts)
       when imdb_id in [nil, ""],
       do: Acquisition.list_releases_by_title(target.title, target.year, opts)

  defp search(:standard, :movie, target, _season, opts),
    do: Acquisition.list_releases(target.imdb_id, opts)

  defp search(:standard, :tv, target, season, opts) do
    episodes = Catalog.manual_search_episodes(target.id, season)

    numbering =
      target
      |> Catalog.anime_series_acquisition_context()
      |> Acquisition.standard_tv_numbering(episodes, MapSet.new([season]))

    # Whole-season packs are verdict-banded per episode (k×band, like the sweep);
    # pass the season's wanted count so a pack isn't judged as one episode's size.
    Acquisition.list_releases_tv(
      target,
      season,
      opts ++
        [
          pack_episode_count: max(length(episodes), 1),
          standard_numbering: numbering
        ]
    )
  end

  defp manual_episode_ids(series, season_number) do
    series.id
    |> Catalog.manual_search_episodes(season_number)
    |> Enum.map(fn episode ->
      episode.id
    end)
  end

  # Mirror the auto-search scorer opts (size band, preferred resolutions/sources,
  # release blocklist, audio pick) so the panel's verdicts and ordering match what the sweep
  # would pick — without them a release the poller rejects as out-of-band shows as acceptable,
  # and one that doesn't satisfy the title's audio pick sorts as high as one that does.
  # The audio pick only RANKS here (`Scorer.rank_key/2`); it never drops a row — the panel is the
  # override surface, and a no-op under an `:anime_policy` by design.
  defp search_opts(:movie, movie) do
    [
      protocols: Download.available_protocols(),
      release_blocklist: Catalog.blocked_release_titles(movie)
    ] ++ language_opts(movie) ++ Acquisition.band_opts(:movies)
  end

  defp search_opts(:tv, series) do
    [
      protocols: Download.available_protocols(),
      release_blocklist: Catalog.blocked_release_titles_for_series(series.id)
    ] ++ language_opts(series) ++ Acquisition.band_opts(:tv)
  end

  defp language_opts(target),
    do: [
      preferred_language: target.preferred_language,
      original_language: target.original_language
    ]

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
    case fetch_release(socket.assigns.results, params["index"] || socket.assigns.confirming) do
      {release, _verdict} ->
        send(self(), {:manual_grab, socket.assigns.mode, socket.assigns.target, release})

      nil ->
        :noop
    end

    {:noreply, assign(socket, :confirming, nil)}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # phx-value-index arrives as a string; resolve it to the {release, verdict} tuple by position.
  defp fetch_release(results, index) when is_binary(index) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 -> Enum.at(results, i)
      _ -> nil
    end
  end

  defp fetch_release(_results, _index), do: nil

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
          :for={{{release, verdict}, index} <- Enum.with_index(@results)}
          class="flex flex-wrap items-center gap-2 text-sm"
        >
          <span class="min-w-0 flex-1 truncate" title={release.title}>{release.title}</span>
          <span class="badge badge-xs">{release.resolution || gettext("?")}</span>
          <.language_badge language={release.language} pick={@audio_pick} />
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
  attr :pick, :any, default: nil

  defp language_badge(assigns) do
    state = language_state(assigns.language, assigns.pick)
    assigns = assign(assigns, state: state, explanation: language_explanation(state))

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

  # How the sweep would actually treat this row, which is not the same question as "does the tag
  # equal the target". `:assumed` is the gap between the two: under a SOFT pick the movie pool
  # passes `keep_untagged: true`, and `Language.keep?/3` deliberately KEEPS untagged releases —
  # non-English scene groups routinely publish original audio with a bare name (issue #191). Badging
  # those a mismatch would accuse, on the override surface, the very rows the sweep is built to
  # accept. They are still ranked below any tagged match; that demotion is `keep_untagged`'s whole
  # contract and `rank_key/2` already applies it.
  defp language_state(_language, nil), do: nil

  defp language_state(language, {strict?, target}) do
    cond do
      Language.satisfies_lang?(language, target) -> :match
      language in [nil, ""] and not strict? -> :assumed
      true -> :mismatch
    end
  end

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

  defp verdict_reason(_), do: ""
end
