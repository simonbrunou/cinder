defmodule CinderWeb.SeriesDetailLive do
  @moduledoc """
  Admin-only series detail at `/series/:id`: the season/episode tree with per-episode
  monitor toggles and a per-season bulk control. Writes go straight through
  `Catalog.set_episode_monitored/2` / `set_season_monitored/2` (monitor flags aren't
  pipeline state, so no `Catalog.transition`). Subscribes to the `"series"` topic so a
  second open tab reflects a toggle.
  """
  use CinderWeb, :live_view

  import CinderWeb.AliasHelpers, only: [alias_form: 0]
  import CinderWeb.RequestHelpers, only: [normalize_profile: 2]

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}
  alias CinderWeb.AliasHelpers
  alias CinderWeb.SeriesDetailComponents

  @picks Language.preferences()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # The :id param is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %{} = series <- Catalog.get_series_with_tree(id) do
      if connected?(socket), do: Catalog.subscribe_series()

      socket =
        assign(socket,
          confirming: nil,
          alias_form: alias_form(),
          confirm_opt: false,
          searching_season: nil,
          mapping_grabs: Catalog.list_mapping_grabs_for_series(series.id),
          episode_groups: nil,
          numbering_panel_open?: false,
          scene_saving_group_id: nil,
          offset_form: offset_form(),
          offset_preview: nil,
          open_seasons: MapSet.new()
        )
        |> refresh_identity(series)

      {:ok, maybe_enrich(socket, series)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Series not found."))
         |> push_navigate(to: ~p"/library?type=tv")}
    end
  end

  @impl true
  def handle_event("toggle_episode", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id) do
      case Catalog.set_episode_monitored(ep, !ep.monitored) do
        {:ok, _} ->
          {:noreply, reload(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't update the episode."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_season", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      # Bulk action: if every episode is already monitored, turn the season off; else on.
      case Catalog.set_season_monitored(season, not all_monitored?(season)) do
        {:ok, _} ->
          {:noreply, reload(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't update the season."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Seasons render as native <details>, whose open state lives only in the browser DOM. Any
  # {:series_updated} reload (the 12h refresher, a grab landing, another tab's toggle) re-patches
  # the seasons comprehension and strips the browser-set `open`, snapping expanded seasons shut.
  # Tracking the open set here lets the render re-assert `open` on every patch so it survives.
  # ponytail: the native toggle flips instantly on click and this records it a beat later; a
  # background reload landing inside that click→server window could still flicker one season. A
  # phx-hook mirroring the DOM `toggle` event would close that gap — add it only if seen.
  def handle_event("toggle_season_open", %{"id" => id}, socket) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} ->
        open = socket.assigns.open_seasons

        open =
          if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)

        {:noreply, assign(socket, open_seasons: open)}

      _ ->
        {:noreply, socket}
    end
  end

  # Series-level "Find a better match" shortcut (the header entry point): expand every season
  # whose upgrade search would do something, so the otherwise-collapsed per-season controls become
  # visible. Unions into the open set so a season the operator already opened stays open; the
  # header button focuses the first such season client-side.
  def handle_event("reveal_manual_search", _params, socket) do
    open = MapSet.union(socket.assigns.open_seasons, searchable_season_ids(socket))
    {:noreply, assign(socket, open_seasons: open)}
  end

  def handle_event("ask_cancel_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :cancel, confirm_opt: false)}

  def handle_event("ask_delete_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :delete, confirm_opt: false)}

  def handle_event("ask_delete_episode_file", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:episode_file, id}, confirm_opt: false)}

  def handle_event("ask_delete_season_files", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:season_files, id}, confirm_opt: false)}

  def handle_event("toggle_confirm_opt", _params, socket),
    do: {:noreply, assign(socket, confirm_opt: !socket.assigns.confirm_opt)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, confirm_opt: false)}

  def handle_event("confirm_cancel_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.cancel_series(socket.assigns.series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:info, gettext("Series cancelled."))
         |> reload()}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't cancel the series."))}
    end
  end

  def handle_event("confirm_delete_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_series(socket.assigns.series, actor,
           delete_files: socket.assigns.confirm_opt
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Series deleted."))
         |> push_navigate(to: ~p"/library?type=tv")}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the series."))}
    end
  end

  def handle_event("confirm_delete_episode_file", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id),
         {:ok, _} <- Catalog.delete_episode_file(ep, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply,
       socket
       |> assign(confirming: nil)
       |> put_flash(:info, gettext("Episode file deleted."))
       |> reload()}
    else
      {:error, :no_file} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("That episode has no file."))}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the episode file."))}
    end
  end

  def handle_event("confirm_delete_season_files", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      result = Catalog.delete_season_files(season, actor, unmonitor: socket.assigns.confirm_opt)
      socket = assign(socket, confirming: nil)

      socket =
        case result do
          {:ok, cleared, 0} ->
            put_flash(socket, :info, gettext("Deleted %{count} file(s).", count: cleared))

          {:ok, cleared, failed} when cleared > 0 ->
            put_flash(
              socket,
              :warning,
              gettext(
                "Deleted %{cleared} file(s); %{failed} could not be deleted (see server logs).",
                cleared: cleared,
                failed: failed
              )
            )

          {:ok, _cleared, _failed} ->
            put_flash(
              socket,
              :error,
              gettext("Couldn't delete the season's files (see server logs).")
            )

          _ ->
            put_flash(socket, :error, gettext("Couldn't delete the season files."))
        end

      {:noreply, reload(socket)}
    else
      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the season files."))}
    end
  end

  def handle_event("set_series_language", %{"preferred_language" => lang}, socket)
      when lang in @picks do
    case Catalog.set_series_language(socket.assigns.series, lang) do
      {:ok, series} ->
        {:noreply, assign(socket, :series, series)}

      {:error, _} ->
        # The dropdown visually snaps back — say why, like the sibling toggles do.
        {:noreply, put_flash(socket, :error, gettext("Couldn't update the language."))}
    end
  end

  def handle_event("set_media_profile", %{"profile_id" => raw}, socket) do
    # On success the self-received {:series_updated} broadcast reloads @series — no
    # explicit reload needed.
    with {:ok, profile} <- normalize_profile(raw, :tv),
         {:ok, _} <- Catalog.assign_profile(socket.assigns.series, profile) do
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't update the profile."))}
    end
  end

  def handle_event("set_media_profile", %{"media_profile" => raw}, socket) do
    handle_event("set_media_profile", %{"profile_id" => raw}, socket)
  end

  def handle_event("set_monitor_strategy", %{"monitor_strategy" => strategy}, socket)
      when strategy in ["all", "future", "none"] do
    # Full tree reset (per-episode toggles overwritten, specials unmonitored) — see
    # Catalog.set_series_monitor_strategy/2. On success the self-received
    # {:series_updated} broadcast reloads @series with the updated tree.
    case Catalog.set_series_monitor_strategy(
           socket.assigns.series,
           String.to_existing_atom(strategy)
         ) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update monitoring."))}
    end
  end

  def handle_event("save_alias", %{"alias" => params}, socket) when is_map(params) do
    AliasHelpers.save_alias(socket, socket.assigns.series, params, &refresh_identity/2)
  end

  def handle_event("edit_alias", %{"id" => id}, socket),
    do: AliasHelpers.edit_alias(socket, socket.assigns.series, id)

  def handle_event("cancel_alias_edit", _params, socket),
    do: AliasHelpers.cancel_alias_edit(socket)

  def handle_event("delete_alias", %{"id" => id}, socket),
    do: AliasHelpers.delete_alias(socket, socket.assigns.series, id, &refresh_identity/2)

  def handle_event("search_episode", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id) do
      # Don't flash "Searching…" for a search that was never queued.
      case Catalog.search_episode_now(ep) do
        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't queue the search."))}

        _ ->
          {:noreply, put_flash(socket, :info, gettext("Searching for this episode…"))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("search_season", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      Catalog.search_season_now(season)
      {:noreply, put_flash(socket, :info, gettext("Searching for missing episodes…"))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Toggle the manual-search panel for a season (re-clicking the open season closes it).
  def handle_event("tv_manual_search", %{"season" => n}, socket) when is_binary(n) do
    case Integer.parse(n) do
      {season, ""} ->
        open = if socket.assigns.searching_season == season, do: nil, else: season
        {:noreply, assign(socket, searching_season: open)}

      _ ->
        {:noreply, socket}
    end
  end

  # A group selection change previews its derived mapping (no persistence); clearing back to
  # "None" just resets the form and drops the preview. `scene_selected_group_id` is stamped on
  # every change so a stale preview for a since-abandoned selection (switch to another group, or
  # clear back to None, before the fetch lands) is recognizable and discarded in handle_async.
  def handle_event("preview_scene_group", %{"group_id" => group_id}, socket)
      when is_binary(group_id) do
    socket =
      assign(socket,
        scene_form: to_form(%{"group_id" => group_id}),
        scene_preview: nil,
        scene_selected_group_id: group_id
      )

    case group_id do
      "" -> {:noreply, cancel_async(socket, :preview_scene_group)}
      id -> {:noreply, start_scene_preview(socket, id)}
    end
  end

  # TMDB calls run off-process via start_async, never inline (mirrors preview_scene_group
  # above) — set_scene_numbering_group/3 fetches the group detail live before it can write,
  # unless the last-landed preview already fetched this exact group (scene_detail), in which
  # case that detail is threaded through to skip the redundant round trip. `scene_saving_group_id`
  # is stamped synchronously so refresh_identity can recognize this group as "our own action" no
  # matter which path notices it landed first — the {:series_updated} broadcast this save's own
  # write triggers reaches this same process (and is handled) *before* the async task below
  # delivers its own result, so both reload paths need the signal, not just this task's own
  # landing. Cleared once this task's own result confirms the save is fully settled.
  def handle_event("save_scene_numbering_group", %{"group_id" => group_id}, socket) do
    series = socket.assigns.series
    opts = scene_save_opts(socket, group_id)

    {:noreply,
     socket
     |> assign(:scene_saving_group_id, group_id)
     |> start_async(:save_scene_numbering_group, fn ->
       {group_id, Catalog.set_scene_numbering_group(series, group_id, opts)}
     end)}
  end

  # Lazy-loaded on first open of the "Alternate numbering" disclosure (a non-anime series never
  # renders it, so it never fetches). The native <details> toggle and this phx-click fire
  # together on BOTH open and close, so `numbering_panel_open?` is a plain toggle tracking which
  # one just happened — refresh_identity reads it to gate its external-change auto-refetch on
  # the panel actually being open (a closed panel shouldn't spend a live TMDB call on a preview
  # nobody's looking at). Reopening after an external change landed while closed (group list
  # already loaded, a group is saved, but the preview was cleared and never refetched) catches up
  # here instead of leaving the panel permanently blank. Retry (below) is the only way back out
  # of :error.
  def handle_event("load_episode_groups", _params, socket) do
    open? = not socket.assigns.numbering_panel_open?
    socket = assign(socket, :numbering_panel_open?, open?)

    cond do
      not open? ->
        {:noreply, socket}

      is_nil(socket.assigns.episode_groups) ->
        {:noreply, fetch_episode_groups(socket)}

      is_list(socket.assigns.episode_groups) and is_nil(socket.assigns.scene_preview) and
          is_binary(socket.assigns.series.scene_numbering_group_id) ->
        {:noreply, start_scene_preview(socket, socket.assigns.series.scene_numbering_group_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("retry_episode_groups", _params, socket) do
    {:noreply, fetch_episode_groups(socket)}
  end

  # Offset generator (issue #156): the derivation is pure (no TMDB call), so the preview is computed
  # in-process on every change and Save/Clear write immediately — no start_async needed. Non-numeric
  # or partial input yields no preview and a save error, never a crash (house-style tolerance).
  def handle_event("preview_scene_offset", %{"from" => from, "delta" => delta}, socket) do
    {:noreply,
     assign(socket,
       offset_form: to_form(%{"from" => from, "delta" => delta}),
       offset_preview: build_offset_preview(socket.assigns.series, from, delta)
     )}
  end

  def handle_event("save_scene_offset", %{"from" => from, "delta" => delta}, socket) do
    case Catalog.save_scene_offset_coordinates(
           socket.assigns.series,
           parse_offset_int(from),
           parse_offset_int(delta)
         ) do
      {:ok, _series} ->
        {:noreply, socket |> put_flash(:info, gettext("Season offset saved.")) |> reload()}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Enter a starting season (1 or more) and a non-zero shift.")
         )}
    end
  end

  def handle_event("clear_scene_offset", _params, socket) do
    case Catalog.save_scene_offset_coordinates(socket.assigns.series, nil, nil) do
      {:ok, _series} ->
        {:noreply,
         socket
         |> assign(offset_form: offset_form(), offset_preview: nil)
         |> put_flash(:info, gettext("Season offset cleared."))
         |> reload()}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Refresh descriptive metadata off the render path whenever the detail page opens (house
  # pattern from the M4b add flow — TMDB calls run off-process via start_async, never inline in
  # mount/3). The episode-group list is fetched lazily instead (see "load_episode_groups" above).
  defp maybe_enrich(socket, %Series{} = series) do
    if connected?(socket) do
      start_async(socket, :enrich, fn -> Catalog.enrich_series(series) end)
    else
      socket
    end
  end

  defp fetch_episode_groups(socket) do
    series = socket.assigns.series
    start_async(socket, :load_episode_groups, fn -> Catalog.list_episode_groups(series) end)
  end

  # Cancels any still-in-flight preview fetch before starting a new one (safe to call when
  # nothing is running) — an operator picking a different group before the auto-fired preview
  # for the saved one lands would otherwise leave that first TMDB round trip running for nothing
  # (its result is already discarded by the group-id guard in handle_async, this just stops
  # wasting the request).
  defp start_scene_preview(socket, group_id) do
    socket
    |> cancel_async(:preview_scene_group)
    |> start_async(:preview_scene_group, fn ->
      {group_id, Catalog.get_episode_group(group_id)}
    end)
  end

  defp scene_save_opts(socket, group_id) do
    case socket.assigns.scene_detail do
      {^group_id, detail} -> [detail: detail]
      _ -> []
    end
  end

  # Metadata refresh landed — reload so the tree + the newly-written descriptive fields render.
  @impl true
  def handle_async(:enrich, {:ok, %Series{}}, socket), do: {:noreply, reload(socket)}
  def handle_async(:enrich, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load_episode_groups, {:ok, {:ok, groups}}, socket) do
    socket = assign(socket, :episode_groups, groups)

    # A series that already has a saved group shows the right selection but a blank preview
    # until now — auto-fire it once the list (and thus the form) is ready to render.
    case socket.assigns.series.scene_numbering_group_id do
      nil -> {:noreply, socket}
      group_id -> {:noreply, start_scene_preview(socket, group_id)}
    end
  end

  def handle_async(:load_episode_groups, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, :episode_groups, :error)}

  def handle_async(:load_episode_groups, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :episode_groups, :error)}

  def handle_async(:preview_scene_group, {:ok, {group_id, result}}, socket) do
    # Discard a stale result: the operator moved on to a different selection (or cleared to
    # None) before this fetch landed.
    if group_id == socket.assigns.scene_selected_group_id do
      case result do
        {:ok, detail} ->
          preview = Catalog.preview_scene_mapping(detail, socket.assigns.series)
          {:noreply, assign(socket, scene_preview: preview, scene_detail: {group_id, detail})}

        {:error, _reason} ->
          {:noreply, assign(socket, :scene_preview, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:preview_scene_group, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :scene_preview, :error)}

  def handle_async(:save_scene_numbering_group, {:ok, {group_id, {:ok, _series}}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Alternate numbering saved."))
     |> reload()
     |> clear_scene_saving(group_id)}
  end

  def handle_async(
        :save_scene_numbering_group,
        {:ok, {group_id, {:error, :group_fetch_failed}}},
        socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Couldn't reach TMDB. Nothing was saved. Try again."))
     |> clear_scene_saving(group_id)}
  end

  def handle_async(:save_scene_numbering_group, {:ok, {group_id, {:error, _reason}}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Couldn't save the alternate numbering."))
     |> clear_scene_saving(group_id)}
  end

  def handle_async(:save_scene_numbering_group, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Couldn't save the alternate numbering."))
     |> assign(:scene_saving_group_id, nil)}
  end

  # Only clears the "own save in flight" signal if it still points at THIS save (a second Save
  # clicked before the first's result lands would otherwise have its own tracking wiped by the
  # earlier, now-stale one landing).
  defp clear_scene_saving(socket, group_id) do
    if socket.assigns.scene_saving_group_id == group_id do
      assign(socket, :scene_saving_group_id, nil)
    else
      socket
    end
  end

  # The manual-search panel forwards a chosen release back here (it owns no Catalog writes). The
  # open panel's season is tracked in :searching_season; the grab covers that season's wanted set.
  @impl true
  def handle_info({:manual_grab, :tv, series, release}, socket) do
    {level, msg} =
      case Catalog.manual_grab_tv(series, socket.assigns.searching_season, release) do
        {:ok, _grab} ->
          {:info, gettext("Grabbing the selected release…")}

        {:error, :nothing_wanted} ->
          {:error, gettext("Nothing left to grab this season.")}

        {:error, :conflicting_standard_numbering} ->
          {:error, gettext("This release's episode numbering is ambiguous. Nothing was grabbed.")}

        {:error, _} ->
          {:error, gettext("Couldn't grab that release.")}
      end

    {:noreply, socket |> assign(searching_season: nil) |> put_flash(level, msg) |> reload()}
  end

  def handle_info({:series_updated, id}, socket) do
    if id == socket.assigns.series.id, do: {:noreply, reload(socket)}, else: {:noreply, socket}
  end

  def handle_info({:series_deleted, id}, socket) do
    if socket.assigns.series.id == id do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Series deleted."))
       |> push_navigate(to: ~p"/library?type=tv")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Guard the series vanishing out from under an open page (no delete path today, but a
  # reload that assigned nil would nil-deref the next render): bounce back to the list.
  defp reload(socket) do
    case Catalog.get_series_with_tree(socket.assigns.series.id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Series not found."))
        |> push_navigate(to: ~p"/library?type=tv")

      series ->
        socket
        |> assign(mapping_grabs: Catalog.list_mapping_grabs_for_series(series.id))
        |> refresh_identity(series)
    end
  end

  # Runs on every reload — any {:series_updated} broadcast (another tab's monitor toggle, the
  # 12h refresher, our OWN successful Save's own write) as well as the mount-time :enrich landing
  # — so it must never discard an operator's in-progress, unsaved alternate-numbering selection
  # while its preview is still on screen. `scene_form`/`scene_selected_group_id` are only reset
  # when the persisted group actually changed relative to what was last assigned (compared before
  # `series` below overwrites it); the very first mount has no prior series to compare against, so
  # it always resets there.
  #
  # `scene_saving_group_id` (stamped by the save handler, cleared once its own async result lands)
  # is checked ahead of the operator's current selection: a Save's own write broadcasts
  # {:series_updated} *before* its async task delivers its own result, so the broadcast-triggered
  # reload gets here first — both paths need to recognize "this is our own save" the same way, not
  # just the save's own handle_async. Falling back to the current selection when nothing is being
  # saved keeps every other caller's behavior unchanged.
  #
  # A changed persisted value splits three ways:
  #   - it matches our own-save/selection signal AND the operator's current selection — that's
  #     our own action landing with nothing moved on since, so `scene_preview`/`scene_detail` are
  #     kept exactly as they render right now.
  #   - it matches our own-save signal but NOT the operator's current selection — our own Save
  #     landed, but the operator has since picked something else; every scene assign is left
  #     untouched rather than snapping the dropdown back to what was just saved.
  #   - it matches neither — a genuine external change (another tab, the refresher) — so the
  #     stale preview is cleared, and re-fetched immediately if the panel is open and the group
  #     list is already loaded (otherwise the next open re-fetches it, see "load_episode_groups").
  defp refresh_identity(socket, series) do
    aliases = Catalog.list_title_aliases(series)
    old_group = scene_group_id_string(socket.assigns[:series])
    new_group = scene_group_id_string(series)
    current_selection = socket.assigns[:scene_selected_group_id]
    own_id = socket.assigns[:scene_saving_group_id] || current_selection

    socket =
      socket
      |> assign(
        series: series,
        profile_form: profile_form(series),
        profile_summary: Catalog.media_profile_summary(series),
        tv_profiles: Catalog.list_profiles(:tv),
        aliases_empty?: aliases == []
      )
      |> stream(:title_aliases, aliases, reset: true)

    cond do
      old_group == new_group ->
        socket

      new_group == own_id and new_group == current_selection ->
        assign(socket, scene_form: scene_form(series), scene_selected_group_id: new_group)

      new_group == own_id ->
        socket

      true ->
        apply_external_scene_change(socket, series, new_group)
    end
  end

  # A genuine external change (another tab, the refresher): drop the stale preview and, if the
  # panel is open with its group list already loaded, re-fetch the new one immediately.
  defp apply_external_scene_change(socket, series, new_group) do
    socket =
      assign(socket,
        scene_form: scene_form(series),
        scene_selected_group_id: new_group,
        scene_preview: nil,
        scene_detail: nil
      )

    if socket.assigns.numbering_panel_open? and is_list(socket.assigns.episode_groups) and
         new_group != "" do
      start_scene_preview(socket, new_group)
    else
      socket
    end
  end

  defp profile_form(series),
    do: to_form(%{"profile_id" => Map.get(series, :profile_id) || "auto"})

  defp scene_form(series), do: to_form(%{"group_id" => scene_group_id_string(series)})

  defp offset_form, do: to_form(%{"from" => "", "delta" => ""})

  defp build_offset_preview(series, from, delta) do
    case {parse_offset_int(from), parse_offset_int(delta)} do
      {from, delta} when is_integer(from) and is_integer(delta) ->
        Catalog.preview_scene_offset(series, from, delta)

      _partial ->
        nil
    end
  end

  defp parse_offset_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _not_an_int -> nil
    end
  end

  defp parse_offset_int(_value), do: nil

  defp scene_group_id_string(nil), do: nil
  defp scene_group_id_string(series), do: series.scene_numbering_group_id || ""

  defp find_episode(series, id) do
    series.seasons |> Enum.flat_map(& &1.episodes) |> Enum.find(&(&1.id == id))
  end

  defp find_season(series, id), do: Enum.find(series.seasons, &(&1.id == id))

  # The seasons whose per-season "Find a better match" would render — shares the component's
  # predicate so the header shortcut can never expand a season with nothing to search.
  defp searchable_season_ids(socket) do
    profile = socket.assigns.profile_summary

    for season <- socket.assigns.series.seasons,
        SeriesDetailComponents.season_manual_searchable?(season, profile),
        into: MapSet.new(),
        do: season.id
  end

  # Duplicated in `CinderWeb.SeriesDetailComponents` (used there by the template's "Monitor
  # all"/"Unmonitor all" button) — tiny enough to keep as two independent copies.
  defp all_monitored?(%{episodes: []}), do: false
  defp all_monitored?(%{episodes: eps}), do: Enum.all?(eps, & &1.monitored)

  # The template (labels, per-episode/season badge derivation) was carved out to
  # `CinderWeb.SeriesDetailComponents` as plain code motion once this file outgrew ~1,500 lines.
  @impl true
  def render(assigns), do: SeriesDetailComponents.render(assigns)
end
