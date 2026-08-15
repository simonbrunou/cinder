defmodule CinderWeb.SeriesDetailComponents do
  @moduledoc """
  The `/series/:id` template and its pure display helpers (alias/scene-numbering
  labels, per-episode/season badge derivation). Carved out of
  `CinderWeb.SeriesDetailLive` as plain code motion — `render/1` is called
  unchanged from the LiveView's own `render/1` callback; every helper here is
  either template-only or (for `all_monitored?/1`) a small duplicate of the
  LiveView's own copy, per the same file's convention for tiny shared helpers.
  """
  use CinderWeb, :html

  import CinderWeb.AliasHelpers, only: [alias_kind_options: 0, alias_kind_label: 1]

  import CinderWeb.LiveHelpers,
    only: [format_date_year: 1, humanize_bytes: 1, rating: 1, media_title: 2, media_overview: 2]

  alias Cinder.Catalog
  alias Cinder.Catalog.Episode

  def render(assigns) do
    # The first season with a manual-searchable set drives the series-level "Find a better match"
    # header entry point (visible without expanding a season) — nil hides it and its focus target.
    assigns =
      assign(
        assigns,
        :manual_search_season,
        Enum.find(assigns.series.seasons, &season_manual_searchable?(&1, assigns.profile_summary))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <%!-- Back to the tab this series lives on, not the default Movies tab. --%>
      <.link
        navigate={~p"/library?type=tv"}
        class="link link-hover mb-6 inline-flex items-center gap-1"
      >
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Library")}
      </.link>

      <div class="mb-4 flex flex-wrap items-center gap-2">
        <.button type="button" variant="warning" size="sm" phx-click="ask_cancel_series">
          {gettext("Cancel series")}
        </.button>
        <.button type="button" variant="danger" size="sm" phx-click="ask_delete_series">
          {gettext("Delete series")}
        </.button>
        <.button
          id="series-subtitle-sync"
          navigate={~p"/subtitle-sync?series=#{@series.id}"}
          variant="neutral"
          size="sm"
        >
          {gettext("Subtitle sync")}
        </.button>
        <%!-- Series-level shortcut to the per-season upgrade search — the movie page exposes
              "Find a better match" as a top-level button, but on TV it otherwise only lives
              inside a collapsed season. Expands the searchable seasons and focuses the first. --%>
        <.button
          :if={@manual_search_season}
          type="button"
          variant="neutral"
          size="sm"
          phx-click={
            JS.push("reveal_manual_search")
            |> JS.focus(to: "#season-summary-#{@manual_search_season.id}")
          }
          aria-label={gettext("Find a better match: expand the seasons you can search")}
        >
          {gettext("Find a better match")}
        </.button>
      </div>

      <.confirm_action
        :if={@confirming == :cancel}
        id="confirm-cancel-series"
        on_confirm="confirm_cancel_series"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Cancel series")}
        variant="warning"
      >
        <:caveat>
          {gettext("Cancel this series? Removes its downloads and unmonitors everything.")}
        </:caveat>
      </.confirm_action>

      <.confirm_action
        :if={@confirming == :delete}
        id="confirm-delete-series"
        class="mb-6"
        on_confirm="confirm_delete_series"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Delete")}
        checkbox_event="toggle_confirm_opt"
        checkbox_checked={@confirm_opt}
        checkbox_label={gettext("Also delete files from disk")}
      >
        <:caveat>{gettext("Delete this series and its seasons/episodes?")}</:caveat>
      </.confirm_action>

      <div class="mb-8 flex gap-4">
        <img
          :if={@series.poster_path}
          src={poster_url(@series.poster_path)}
          alt={media_title(@series, @locale)}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div class="min-w-0 flex-1">
          <.header>
            {media_title(@series, @locale)}
            <span :if={@series.year} class="font-normal text-base-content/70">({@series.year})</span>
            <:actions>
              <.status_badge kind={:monitored} status={@series.monitored} />
            </:actions>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@series.first_air_date} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@series.first_air_date)}
            </span>
            <span
              :if={is_number(@series.vote_average) and @series.vote_average > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-star" class="size-4" />{rating(@series.vote_average)}
            </span>
          </div>

          <div :if={@series.genres not in [nil, []]} class="mt-2 flex flex-wrap gap-1">
            <span :for={g <- @series.genres} class="badge badge-outline badge-sm">{g}</span>
          </div>

          <p :if={media_overview(@series, @locale)} class="mt-3 max-w-prose text-sm leading-relaxed">
            {media_overview(@series, @locale)}
          </p>
        </div>
      </div>

      <section
        :if={@mapping_grabs != []}
        id="series-mapping-grabs"
        class="mb-6 rounded-box border border-base-300 p-4"
      >
        <h2 class="font-semibold">{gettext("Needs mapping")}</h2>
        <div
          :for={grab <- @mapping_grabs}
          id={"series-mapping-grab-#{grab.id}"}
          class="mt-2 flex flex-wrap items-center gap-2"
        >
          <span class="min-w-0 flex-1 break-words text-sm">{grab.release_title || grab.download_id}</span>
          <.status_badge kind={:grab} status={:needs_mapping} />
          <.link navigate={~p"/activity"} class="link link-hover text-sm">
            {gettext("View in Activity")}
          </.link>
        </div>
      </section>

      <div class="mb-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <form id="series-detail-language-form" phx-change="set_series_language">
          <div class="fieldset mb-2">
            <label>
              <span class="label mb-1">{gettext("Audio")}</span>
              <.language_select value={@series.preferred_language} />
            </label>
          </div>
        </form>
        <div>
          <.form for={@profile_form} id="series-profile-form" phx-change="set_media_profile">
            <.profile_select field={@profile_form[:profile_id]} profiles={@tv_profiles} />
          </.form>
          <.profile_summary id="series-profile-summary" summary={@profile_summary} />
        </div>
        <form id="series-monitor-strategy-form" phx-change="set_monitor_strategy">
          <div class="fieldset mb-2">
            <label>
              <span class="label mb-1">{gettext("Monitoring")}</span>
              <select
                name="monitor_strategy"
                class="select select-sm w-full"
                aria-label={gettext("Monitoring")}
              >
                <option value="all" selected={@series.monitor_strategy == :all}>
                  {gettext("All episodes")}
                </option>
                <option value="future" selected={@series.monitor_strategy == :future}>
                  {gettext("Future episodes")}
                </option>
                <option value="none" selected={@series.monitor_strategy == :none}>
                  {gettext("None")}
                </option>
              </select>
            </label>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext("Reapplies the strategy to every episode, overwriting manual toggles.")}
          </p>
        </form>
      </div>

      <details class="mb-6">
        <summary class="cursor-pointer border-b border-base-300 pb-2 text-lg font-semibold">
          {gettext("Title aliases")}
        </summary>
        <p class="mb-2 mt-2 max-w-prose text-sm text-base-content/70">
          {gettext("Extra titles tried when searching indexers, alongside the main title.")}
        </p>
        <p
          :if={@alias_form[:id].value not in [nil, ""]}
          id="series-alias-edit-status"
          role="status"
          aria-live="polite"
          phx-mounted={JS.focus(to: "#series-alias-title")}
          class="mb-2 text-sm text-base-content/60"
        >
          {gettext("Editing alias %{title}", title: @alias_form[:title].value)}
        </p>
        <.form
          for={@alias_form}
          id="series-alias-form"
          phx-submit="save_alias"
          class="grid items-end gap-x-2 sm:grid-cols-2 lg:grid-cols-5"
        >
          <.input field={@alias_form[:id]} type="hidden" />
          <.input
            field={@alias_form[:title]}
            id="series-alias-title"
            label={gettext("Alias title")}
            required
          />
          <.input
            field={@alias_form[:kind]}
            type="select"
            label={gettext("Alias kind")}
            options={alias_kind_options()}
          />
          <.input field={@alias_form[:country_code]} label={gettext("Country (optional)")} />
          <.input field={@alias_form[:language_code]} label={gettext("Language (optional)")} />
          <div class="mb-2 flex gap-1">
            <.button type="submit" variant="primary" size="sm">{gettext("Save alias")}</.button>
            <.button
              :if={@alias_form[:id].value not in [nil, ""]}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="cancel_alias_edit"
            >
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>

        <div id="series-title-aliases" phx-update="stream" class="divide-y divide-base-200">
          <p
            :if={@aliases_empty?}
            id="series-aliases-empty"
            class="py-2 text-sm text-base-content/60"
          >
            {gettext("No title aliases.")}
          </p>
          <div
            :for={{id, title_alias} <- @streams.title_aliases}
            id={id}
            data-alias={title_alias.title}
            data-source={title_alias.source}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm"
          >
            <span class="font-medium">{title_alias.title}</span>
            <span class="text-xs text-base-content/60">{alias_kind_label(title_alias.kind)}</span>
            <span :if={title_alias.country_code} class="badge badge-ghost badge-xs">
              {title_alias.country_code}
            </span>
            <span :if={title_alias.language_code} class="badge badge-outline badge-xs">
              {title_alias.language_code}
            </span>
            <span class="text-xs text-base-content/50">
              {gettext("Source: %{source}", source: title_alias.source)}
            </span>
            <span :if={title_alias.precedence == :manual} class="ml-auto flex gap-1">
              <.button
                id={"edit-series-alias-#{title_alias.id}"}
                type="button"
                variant="ghost"
                size="sm"
                phx-click={JS.push("edit_alias")}
                phx-value-id={title_alias.id}
                aria-label={gettext("Edit alias %{title}", title: title_alias.title)}
              >
                {gettext("Edit")}
              </.button>
              <.button
                id={"delete-series-alias-#{title_alias.id}"}
                type="button"
                variant="danger"
                size="sm"
                phx-click="delete_alias"
                phx-value-id={title_alias.id}
                aria-label={gettext("Delete alias %{title}", title: title_alias.title)}
              >
                {gettext("Delete")}
              </.button>
            </span>
          </div>
        </div>
      </details>

      <details :if={@profile_summary.effective == :anime} class="mb-6">
        <summary
          class="cursor-pointer border-b border-base-300 pb-2 text-lg font-semibold"
          phx-click="load_episode_groups"
        >
          {gettext("Alternate numbering")}
        </summary>
        <p class="mb-2 mt-2 max-w-prose text-sm text-base-content/70">
          {gettext(
            "Pick a TMDB episode group when indexers number this show differently than TMDB does (e.g. TMDB keeps one continuous season, but releases are split by another season count)."
          )}
        </p>
        <p :if={is_nil(@episode_groups)} class="text-sm text-base-content/60">
          {gettext("Loading episode groups…")}
        </p>
        <div :if={@episode_groups == :error} class="flex items-center gap-2">
          <p class="text-sm text-error">{gettext("Couldn't load episode groups from TMDB.")}</p>
          <.button type="button" variant="ghost" size="sm" phx-click="retry_episode_groups">
            {gettext("Retry")}
          </.button>
        </div>
        <.form
          :if={is_list(@episode_groups)}
          for={@scene_form}
          id="series-scene-numbering-form"
          phx-change="preview_scene_group"
          phx-submit="save_scene_numbering_group"
          class="flex flex-wrap items-end gap-2"
        >
          <.input
            field={@scene_form[:group_id]}
            type="select"
            label={gettext("Episode group")}
            options={scene_group_options(@episode_groups, @series.scene_numbering_group_id)}
            prompt={gettext("None (default numbering)")}
          />
          <.button
            type="submit"
            variant="primary"
            size="sm"
            phx-disable-with={gettext("Saving…")}
          >
            {gettext("Save")}
          </.button>
        </.form>
        <div :if={is_list(@scene_preview)} class="mt-2 text-sm text-base-content/70">
          <p :for={entry <- @scene_preview}>{scene_preview_label(entry)}</p>
        </div>
        <p :if={@scene_preview == :error} class="mt-2 text-sm text-error">
          {gettext("Couldn't load that group's mapping.")}
        </p>
      </details>

      <details :if={@profile_summary.effective == :anime} class="mb-6">
        <summary class="cursor-pointer border-b border-base-300 pb-2 text-lg font-semibold">
          {gettext("Season offset")}
        </summary>
        <p class="mb-2 mt-2 max-w-prose text-sm text-base-content/70">
          {gettext(
            "When releases number this show's seasons with a fixed shift from TMDB (e.g. an inserted season pushes later seasons up by one), generate the matching scene coordinates. Review any native collisions before saving — the alternate numbering wins over that native episode at search time."
          )}
        </p>
        <.form
          for={@offset_form}
          id="series-scene-offset-form"
          phx-change="preview_scene_offset"
          phx-submit="save_scene_offset"
          class="flex flex-wrap items-end gap-2"
        >
          <.input
            field={@offset_form[:from]}
            type="number"
            min="1"
            label={gettext("From TMDB season")}
          />
          <.input field={@offset_form[:delta]} type="number" label={gettext("Season shift (±)")} />
          <.button type="submit" variant="primary" size="sm" phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </.button>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            phx-click="clear_scene_offset"
            aria-label={gettext("Clear season offset")}
          >
            {gettext("Clear")}
          </.button>
        </.form>
        <div :if={is_list(@offset_preview) and @offset_preview != []} class="mt-2 text-sm">
          <p :for={entry <- @offset_preview} class="text-base-content/70">
            {gettext("TMDB S%{tmdb} → S%{scene}", tmdb: entry.tmdb_season, scene: entry.scene_season)}
            <span :if={entry.episode_range}>{episode_range_text(entry.episode_range)}</span>
            <span :if={entry.collisions != []} class="text-warning">
              · {gettext("collides with native %{codes}", codes: Enum.join(entry.collisions, ", "))}
            </span>
          </p>
        </div>
      </details>

      <.empty_state
        :if={@series.seasons == []}
        icon="hero-tv"
        title={gettext("No seasons found")}
        message={gettext("TMDB returned no season data for this series.")}
      />

      <details
        :for={season <- @series.seasons}
        id={"season-#{season.id}"}
        open={MapSet.member?(@open_seasons, season.id)}
        class="mb-6"
      >
        <summary
          id={"season-summary-#{season.id}"}
          class="cursor-pointer border-b border-base-300 pb-2"
          phx-click="toggle_season_open"
          phx-value-id={season.id}
        >
          <span class="text-lg font-semibold">
            {season_label(season.season_number)}
            <span class="ml-2 text-sm font-normal text-base-content/70">
              {gettext("%{n}/%{m} monitored",
                n: monitored_count(season),
                m: length(season.episodes)
              )} · {gettext("%{n}/%{m} available",
                n: available_count(season),
                m: length(season.episodes)
              )}
            </span>
          </span>
        </summary>
        <div class="mb-2 flex flex-wrap justify-end pt-2">
          <div class="flex flex-wrap items-center gap-2">
            <.button
              :if={season.episodes != []}
              type="button"
              phx-click="toggle_season"
              phx-value-id={season.id}
              variant="neutral"
              size="sm"
              aria-label={
                if all_monitored?(season),
                  do:
                    gettext("Unmonitor all episodes in %{season}",
                      season: season_label(season.season_number)
                    ),
                  else:
                    gettext("Monitor all episodes in %{season}",
                      season: season_label(season.season_number)
                    )
              }
            >
              {if all_monitored?(season), do: gettext("Unmonitor all"), else: gettext("Monitor all")}
            </.button>
            <.button
              :if={Enum.any?(season.episodes, & &1.file_path)}
              type="button"
              variant="danger"
              size="sm"
              phx-click="ask_delete_season_files"
              phx-value-id={season.id}
              aria-label={
                gettext("Delete all files in %{season}", season: season_label(season.season_number))
              }
            >
              {gettext("Delete files")}
            </.button>
            <.button
              :if={Enum.any?(season.episodes, &(Episode.file_paths(&1) != []))}
              id={"season-#{season.id}-subtitle-sync"}
              navigate={~p"/subtitle-sync?season=#{season.id}"}
              variant="neutral"
              size="sm"
            >
              {gettext("Subtitle sync")}
            </.button>
            <.button
              :if={season_wanted?(season, @profile_summary)}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="search_season"
              phx-value-id={season.id}
              aria-label={
                gettext("Search all missing episodes in %{season}",
                  season: season_label(season.season_number)
                )
              }
            >
              {gettext("Search all missing")}
            </.button>
            <.button
              :if={season_manual_searchable?(season, @profile_summary)}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="tv_manual_search"
              phx-value-season={season.season_number}
              aria-label={
                gettext("Find a better match in %{season}",
                  season: season_label(season.season_number)
                )
              }
            >
              {gettext("Find a better match")}
            </.button>
          </div>
        </div>

        <.live_component
          :if={@searching_season == season.season_number}
          module={CinderWeb.ManualSearchComponent}
          id={"ms-season-#{season.id}"}
          mode={:tv}
          target={@series}
          season_number={season.season_number}
        />

        <.confirm_action
          :if={@confirming == {:season_files, to_string(season.id)}}
          id={"confirm-delete-season-files-#{season.id}"}
          class="mb-2"
          on_confirm="confirm_delete_season_files"
          on_cancel="dismiss_confirm"
          value={season.id}
          confirm_label={gettext("Delete files")}
          checkbox_event="toggle_confirm_opt"
          checkbox_checked={@confirm_opt}
          checkbox_label={gettext("Also stop monitoring these episodes")}
        >
          <:caveat>
            {gettext(
              "Delete every downloaded file in %{season}? Monitored episodes will be re-downloaded next sweep unless you also stop monitoring.",
              season: season_label(season.season_number)
            )}
          </:caveat>
        </.confirm_action>

        <p :if={season.episodes == []} class="text-sm text-base-content/70">
          {gettext("No episodes yet.")}
        </p>
        <ul class="divide-y divide-base-200">
          <li :for={ep <- season.episodes} id={"episode-#{ep.id}"} class="flex flex-col gap-2 py-2">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
              <div class="flex min-w-0 flex-wrap items-center gap-3 sm:flex-1 sm:flex-nowrap">
                <input
                  type="checkbox"
                  class="toggle shrink-0"
                  checked={ep.monitored}
                  phx-click="toggle_episode"
                  phx-value-id={ep.id}
                  aria-label={
                    gettext("Monitor %{season} episode %{number}",
                      season: season_label(season.season_number),
                      number: ep.episode_number
                    )
                  }
                />
                <span class="shrink-0 text-sm tabular-nums text-base-content/70">
                  {Episode.code(season.season_number, ep.episode_number)}
                </span>
                <span
                  :if={absolute_annotation(ep, @profile_summary)}
                  class="shrink-0 text-xs tabular-nums text-base-content/40"
                >
                  {absolute_annotation(ep, @profile_summary)}
                </span>
                <span class="min-w-0 flex-1 truncate text-sm" title={media_title(ep, @locale)}>
                  {media_title(ep, @locale)}
                </span>
                <span
                  :if={
                    ep.file_path &&
                      (ep.imported_audio_languages || []) ++
                        (ep.imported_embedded_subtitles || []) ++
                        (ep.imported_sidecar_subtitles || []) != []
                  }
                  class="ml-2 inline-flex shrink-0 basis-full flex-wrap gap-1 align-middle sm:basis-auto"
                >
                  <span
                    :for={l <- ep.imported_audio_languages || []}
                    class="badge badge-ghost badge-xs"
                    aria-label={gettext("audio %{lang}", lang: l)}
                  >{l}</span>
                  <span
                    :for={
                      l <-
                        (ep.imported_embedded_subtitles || []) ++
                          (ep.imported_sidecar_subtitles || [])
                    }
                    class="badge badge-outline badge-xs"
                    aria-label={gettext("subtitle %{lang}", lang: l)}
                  >{l}</span>
                </span>
              </div>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 pl-11 sm:pl-0">
                <time
                  :if={ep.air_date}
                  datetime={Date.to_iso8601(ep.air_date)}
                  class="text-xs text-base-content/70"
                >
                  {format_date_year(ep.air_date)}
                </time>
                <span
                  :if={ep.file_path && episode_file_info(ep) != ""}
                  class="text-xs text-base-content/60"
                >
                  {episode_file_info(ep)}
                </span>
                <.button
                  :if={ep.file_path}
                  type="button"
                  variant="danger"
                  size="sm"
                  phx-click="ask_delete_episode_file"
                  phx-value-id={ep.id}
                  aria-label={
                    gettext("Delete file for %{season} episode %{number}",
                      season: season_label(season.season_number),
                      number: ep.episode_number
                    )
                  }
                >
                  {gettext("Delete file")}
                </.button>
                <.button
                  :if={Episode.file_paths(ep) != []}
                  id={"episode-#{ep.id}-subtitle-sync"}
                  navigate={~p"/subtitle-sync?episode=#{ep.id}"}
                  variant="ghost"
                  size="sm"
                >
                  {gettext("Subtitle sync")}
                </.button>
                <.status_badge
                  :if={episode_badge_status(ep, season, @profile_summary)}
                  kind={:episode}
                  status={episode_badge_status(ep, season, @profile_summary)}
                />
                <.button
                  :if={episode_searchable?(ep, season, @profile_summary)}
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="search_episode"
                  phx-value-id={ep.id}
                  aria-label={gettext("Search for episode %{number}", number: ep.episode_number)}
                >
                  {gettext("Search")}
                </.button>
              </div>
            </div>
            <span
              :if={season.season_number == 0}
              class="pl-11 text-xs text-base-content/60 sm:pl-[5.75rem]"
            >
              {classification_label(ep.classification)}
            </span>
            <.confirm_action
              :if={@confirming == {:episode_file, to_string(ep.id)}}
              id={"confirm-delete-episode-file-#{ep.id}"}
              on_confirm="confirm_delete_episode_file"
              on_cancel="dismiss_confirm"
              value={ep.id}
              confirm_label={gettext("Delete file")}
              checkbox_event="toggle_confirm_opt"
              checkbox_checked={@confirm_opt}
              checkbox_label={gettext("Also stop monitoring this episode")}
            >
              <:caveat>
                {gettext(
                  "Delete the downloaded file for this episode? If it stays monitored it will be downloaded again. Stop monitoring it to keep it gone."
                )}
              </:caveat>
            </.confirm_action>
          </li>
        </ul>
      </details>
    </Layouts.app>
    """
  end

  defp episode_range_text({first, first}), do: "E#{first}"
  defp episode_range_text({first, last}), do: "E#{first}–E#{last}"

  defp classification_label(:regular), do: gettext("Regular")
  defp classification_label(:story_special), do: gettext("Story special")
  defp classification_label(:recap), do: gettext("Recap")
  defp classification_label(:extra), do: gettext("Extra")

  # The only coordinate an operator needs: absolute numbering, shown as a small "#1122" next to
  # the episode code — it's how anime releases are actually named. Scene/combined/standard
  # coordinates, and every coordinate/classification source or precedence, are
  # acquisition-internal and stay out of the UI entirely.
  defp absolute_annotation(%{coordinate_memberships: memberships}, %{effective: :anime}) do
    Enum.find_value(memberships, fn membership ->
      case membership.episode_coordinate do
        %{scheme: "absolute", canonical_value: value} -> "##{value}"
        _ -> nil
      end
    end)
  end

  defp absolute_annotation(_episode, _profile), do: nil

  # `saved_group_id` (the series' persisted scene_numbering_group_id) is appended as a synthetic
  # option — labeled with the raw id and an "unavailable" hint — whenever the loaded list doesn't
  # contain it, so the select never silently shows "None" while a group is actually saved (which
  # would make an innocent Save wipe the working configuration).
  defp scene_group_options(groups, saved_group_id) do
    options = Enum.map(groups, &{scene_group_label(&1), &1.id})

    if is_binary(saved_group_id) and
         not Enum.any?(options, fn {_label, id} -> id == saved_group_id end) do
      options ++ [{missing_scene_group_label(saved_group_id), saved_group_id}]
    else
      options
    end
  end

  # group_count/episode_count are integer() | nil per the TMDB behaviour — only the parts TMDB
  # actually returned show up in the parenthetical.
  defp scene_group_label(group) do
    parts = [episode_group_type_label(group.type) | scene_group_counts(group)]
    "#{group.name} (#{Enum.join(parts, ", ")})"
  end

  defp scene_group_counts(group) do
    [
      group.group_count && "#{group.group_count} groups",
      group.episode_count && "#{group.episode_count} episodes"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp missing_scene_group_label(group_id),
    do: gettext("%{group_id} (unavailable on TMDB)", group_id: group_id)

  defp episode_group_type_label(2), do: gettext("Absolute")
  defp episode_group_type_label(4), do: gettext("Digital")
  defp episode_group_type_label(5), do: gettext("Story Arc")
  defp episode_group_type_label(6), do: gettext("Seasons")
  defp episode_group_type_label(7), do: gettext("TV")
  defp episode_group_type_label(_type), do: gettext("Other")

  # Two shapes: every entry unmatched (no alt/canonical range to show — just the count), or
  # at least one matched entry (the alt SxxEyy range Save writes, alongside the canonical
  # episode range it resolves to; an unmatched remainder gets an appended note). Both carry
  # `group_name`/`season_source` so an order-derived season (a convention, not an API guarantee)
  # shows the raw subgroup name it was guessed from — the safety net before Save.
  defp scene_preview_label(%{count: 0, unmatched_count: unmatched} = entry) do
    ngettext(
      "%{season} → %{count} entry doesn't match your episodes.",
      "%{season} → %{count} entries don't match your episodes.",
      unmatched,
      season: scene_season_label(entry),
      count: unmatched
    )
  end

  defp scene_preview_label(
         %{
           season_number: season,
           unmatched_count: unmatched,
           alt_numbers: alt_numbers,
           canonical_range: {first, last}
         } = entry
       ) do
    base =
      gettext("%{season} → %{alt} (episodes %{first}–%{last})",
        season: scene_season_label(entry),
        alt: Episode.codes_label(season, alt_numbers),
        first: first,
        last: last
      )

    if unmatched > 0 do
      base <> " " <> scene_unmatched_note(unmatched)
    else
      base
    end
  end

  defp scene_season_label(%{season_number: season, season_source: :order, group_name: name}),
    do: gettext("%{season} (\"%{name}\")", season: season_label(season), name: name)

  defp scene_season_label(%{season_number: season}), do: season_label(season)

  defp scene_unmatched_note(unmatched) do
    ngettext(
      "%{count} entry doesn't match your episodes.",
      "%{count} entries don't match your episodes.",
      unmatched,
      count: unmatched
    )
  end

  # Duplicated from `CinderWeb.SeriesDetailLive`'s own copy (used there by the
  # "toggle_season" handler) — tiny enough to keep as two independent copies. The template's
  # only call site is already guarded by `season.episodes != []` (the "Monitor all" button),
  # so the empty-list clause the LiveView's copy carries is unreachable here and the type
  # checker rejects it as dead code — a single clause is the equivalent, reachable shape.
  defp all_monitored?(%{episodes: eps}), do: Enum.all?(eps, & &1.monitored)

  # A season has something the search sweep would actually pick up.
  defp season_wanted?(%{episodes: episodes} = season, profile),
    do: Enum.any?(episodes, &episode_searchable?(&1, season, profile))

  @doc """
  Whether a season has any episode the manual "Find a better match" search would act on: an
  already-downloaded episode not currently owned by a grab (upgrade candidate) or a
  sweep-searchable one. Public so `SeriesDetailLive`'s reveal handler shares this exact test.

  Manual search also covers available episodes (monitoring only gates the automatic sweep), but
  never an episode already owned by another grab.
  """
  def season_manual_searchable?(%{episodes: episodes} = season, profile) do
    Enum.any?(
      episodes,
      &((&1.file_path not in [nil, ""] and is_nil(&1.grab_id)) or
          episode_searchable?(&1, season, profile))
    )
  end

  # Eligibility lives in Catalog so the sweep and detail actions cannot drift.
  # Episodes arrive nested under their season rather than with the back-reference
  # preloaded; attaching that already-loaded parent is a pure in-memory operation.
  # The current profile summary is already assigned for the page, so passing it
  # through also keeps Auto's effective Standard semantics identical to the query.
  # No extra database query is needed while rendering the episode list.
  defp episode_searchable?(episode, season, profile),
    do: Catalog.episode_searchable?(%{episode | season: season}, profile)

  # The per-episode state badge, or nil for no badge (same derivation + component as /calendar).
  # A file or active grab is real disk state, so :available/:downloading always show. The
  # sweep-facing states only make sense for an episode the sweep acts on — an unmonitored
  # back-catalog episode (e.g. a :future-strategy series) isn't "Wanted", so it gets no badge.
  # :upcoming keys off `monitored` (unaired episodes are never episode_searchable?); :wanted and
  # :search_parked reuse episode_searchable? so this can't drift from the calendar/sweep.
  defp episode_badge_status(episode, season, profile) do
    case Catalog.episode_state(episode) do
      state when state in [:available, :downloading] -> state
      :upcoming -> if episode.monitored, do: :upcoming
      state -> if episode_searchable?(episode, season, profile), do: state
    end
  end

  defp monitored_count(season), do: Enum.count(season.episodes, & &1.monitored)
  defp available_count(season), do: Enum.count(season.episodes, & &1.file_path)

  # "1080p · 2.1 GB" for a downloaded episode — drops whichever piece TMDB/import didn't capture.
  defp episode_file_info(ep) do
    [ep.imported_resolution, humanize_bytes(ep.imported_size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
