defmodule CinderWeb.SeriesDetailLive do
  @moduledoc """
  Admin-only series detail at `/series/:id`: the season/episode tree with per-episode
  monitor toggles and a per-season bulk control. Writes go straight through
  `Catalog.set_episode_monitored/2` / `set_season_monitored/2` (monitor flags aren't
  pipeline state, so no `Catalog.transition`). Subscribes to the `"series"` topic so a
  second open tab reflects a toggle.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [format_date_year: 1, humanize_bytes: 1, rating: 1]

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  @picks Language.preferences()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # The :id param is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %{} = series <- Catalog.get_series_with_tree(id) do
      if connected?(socket), do: Catalog.subscribe_series()

      socket =
        assign(socket,
          editing?: false,
          confirming: nil,
          form: nil,
          alias_form: alias_form(),
          confirm_opt: false,
          searching_season: nil,
          mapping_grabs: Catalog.list_mapping_grabs_for_series(series.id),
          episode_groups: nil
        )
        |> refresh_identity(series)

      {:ok, maybe_enrich(socket, series)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Series not found."))
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def handle_event("toggle_episode", %{"id" => id}, socket) do
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

  def handle_event("toggle_season", %{"id" => id}, socket) do
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

  def handle_event("edit_series", _params, socket) do
    form = to_form(Series.admin_changeset(socket.assigns.series, %{}))
    {:noreply, assign(socket, editing?: true, confirming: nil, form: form)}
  end

  def handle_event("cancel_edit_series", _params, socket) do
    {:noreply, assign(socket, editing?: false, form: nil)}
  end

  def handle_event("save_series", %{"series" => attrs}, socket) do
    case Catalog.update_series(socket.assigns.series, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing?: false, form: nil)
         |> put_flash(:info, gettext("Series updated."))
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("ask_cancel_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :cancel, editing?: false, confirm_opt: false)}

  def handle_event("ask_delete_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :delete, editing?: false, confirm_opt: false)}

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
         socket |> put_flash(:info, gettext("Series deleted.")) |> push_navigate(to: ~p"/library")}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the series."))}
    end
  end

  def handle_event("confirm_delete_episode_file", %{"id" => id}, socket) do
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

  def handle_event("confirm_delete_season_files", %{"id" => id}, socket) do
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

  def handle_event("set_media_profile", %{"media_profile" => profile}, socket)
      when profile in ["auto", "standard", "anime"] do
    # On success the self-received {:series_updated} broadcast reloads @series — no
    # explicit reload needed.
    case Catalog.set_media_profile(socket.assigns.series, String.to_existing_atom(profile)) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update the profile."))}
    end
  end

  def handle_event("save_alias", %{"alias" => params}, socket) when is_map(params) do
    result =
      case params["id"] do
        id when id in [nil, ""] -> Catalog.save_manual_alias(socket.assigns.series, params)
        id -> update_current_alias(socket.assigns.series, parse_alias_id(id), params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:alias_form, alias_form())
         |> refresh_identity(socket.assigns.series)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:alias_form, alias_form(params))
         |> put_flash(:error, gettext("Couldn't save the alias."))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_alias", %{"id" => id}, socket) do
    with id when not is_nil(id) <- parse_alias_id(id),
         alias_record when not is_nil(alias_record) <-
           current_manual_alias(socket.assigns.series, id) do
      {:noreply, assign(socket, :alias_form, alias_form(alias_record))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_alias_edit", _params, socket),
    do: {:noreply, assign(socket, :alias_form, alias_form())}

  def handle_event("delete_alias", %{"id" => id}, socket) do
    with id when not is_nil(id) <- parse_alias_id(id),
         alias_record when not is_nil(alias_record) <-
           current_manual_alias(socket.assigns.series, id),
         {:ok, _} <- Catalog.delete_manual_alias(socket.assigns.series, alias_record.id) do
      {:noreply, refresh_identity(socket, socket.assigns.series)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("search_episode", %{"id" => id}, socket) do
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

  def handle_event("search_season", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      Catalog.search_season_now(season)
      {:noreply, put_flash(socket, :info, gettext("Searching for missing episodes…"))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Toggle the manual-search panel for a season (re-clicking the open season closes it).
  def handle_event("tv_manual_search", %{"season" => n}, socket) do
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
  def handle_event("preview_scene_group", %{"group_id" => group_id}, socket) do
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
  # case that detail is threaded through to skip the redundant round trip.
  def handle_event("save_scene_numbering_group", %{"group_id" => group_id}, socket) do
    series = socket.assigns.series
    opts = scene_save_opts(socket, group_id)

    {:noreply,
     start_async(socket, :save_scene_numbering_group, fn ->
       Catalog.set_scene_numbering_group(series, group_id, opts)
     end)}
  end

  # Lazy-loaded on first open of the "Alternate numbering" disclosure (a non-anime series never
  # renders it, so it never fetches). The native <details> toggle and this phx-click fire
  # together on BOTH open and close, so the guard only fetches the very first time
  # (episode_groups still nil) — otherwise closing the panel after a failed load would refire a
  # live TMDB call every close/reopen. Retry (below) is the only way back out of :error.
  def handle_event("load_episode_groups", _params, socket) do
    if is_nil(socket.assigns.episode_groups) do
      {:noreply, fetch_episode_groups(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_episode_groups", _params, socket) do
    {:noreply, fetch_episode_groups(socket)}
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

  def handle_async(:save_scene_numbering_group, {:ok, {:ok, _series}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Alternate numbering saved."))
     |> reload()}
  end

  def handle_async(:save_scene_numbering_group, {:ok, {:error, :group_fetch_failed}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Couldn't reach TMDB. Nothing was saved. Try again.")
     )}
  end

  def handle_async(:save_scene_numbering_group, {:ok, {:error, _reason}}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Couldn't save the alternate numbering."))}

  def handle_async(:save_scene_numbering_group, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Couldn't save the alternate numbering."))}

  # The manual-search panel forwards a chosen release back here (it owns no Catalog writes). The
  # open panel's season is tracked in :searching_season; the grab covers that season's wanted set.
  @impl true
  def handle_info({:manual_grab, :tv, series, release}, socket) do
    {level, msg} =
      case Catalog.manual_grab_tv(series, socket.assigns.searching_season, release) do
        {:ok, _grab} -> {:info, gettext("Grabbing the selected release…")}
        {:error, :nothing_wanted} -> {:error, gettext("Nothing left to grab this season.")}
        {:error, _} -> {:error, gettext("Couldn't grab that release.")}
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
       |> push_navigate(to: ~p"/library")}
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
        |> push_navigate(to: ~p"/library")

      series ->
        socket
        |> assign(mapping_grabs: Catalog.list_mapping_grabs_for_series(series.id))
        |> refresh_identity(series)
    end
  end

  # Runs on every reload — any {:series_updated} broadcast (another tab's monitor toggle, the
  # 12h refresher, our OWN successful Save) as well as the mount-time :enrich landing — so it
  # must never discard an operator's in-progress, unsaved alternate-numbering selection while its
  # preview is still on screen. `scene_form`/`scene_selected_group_id` are only reset when the
  # persisted group actually changed relative to what was last assigned (compared before `series`
  # below overwrites it); the very first mount has no prior series to compare against, so it
  # always resets there.
  #
  # A changed persisted value splits two ways:
  #   - it now matches `scene_selected_group_id` (what THIS session already picked and
  #     previewed) — that's our own Save landing, so `scene_preview`/`scene_detail` are kept
  #     exactly as they render right now.
  #   - it doesn't — a genuine external change (another tab, the refresher) — so the stale
  #     preview is cleared, and re-fetched immediately if the group list is already loaded
  #     (otherwise the next open, or `load_episode_groups`' own auto-preview, repopulates it).
  defp refresh_identity(socket, series) do
    aliases = Catalog.list_title_aliases(series)
    old_group = scene_group_id_string(socket.assigns[:series])
    new_group = scene_group_id_string(series)

    socket =
      socket
      |> assign(
        series: series,
        profile_form: profile_form(series),
        profile_summary: Catalog.media_profile_summary(series),
        aliases_empty?: aliases == []
      )
      |> stream(:title_aliases, aliases, reset: true)

    cond do
      old_group == new_group ->
        socket

      new_group == socket.assigns[:scene_selected_group_id] ->
        assign(socket, scene_form: scene_form(series), scene_selected_group_id: new_group)

      true ->
        socket =
          assign(socket,
            scene_form: scene_form(series),
            scene_selected_group_id: new_group,
            scene_preview: nil,
            scene_detail: nil
          )

        if is_list(socket.assigns.episode_groups) and new_group != "" do
          start_scene_preview(socket, new_group)
        else
          socket
        end
    end
  end

  defp profile_form(series),
    do: to_form(%{"media_profile" => Atom.to_string(series.media_profile)})

  defp scene_form(series), do: to_form(%{"group_id" => scene_group_id_string(series)})

  defp scene_group_id_string(nil), do: nil
  defp scene_group_id_string(series), do: series.scene_numbering_group_id || ""

  defp alias_form(params \\ %{})

  defp alias_form(%Cinder.Catalog.TitleAlias{} = alias_record) do
    alias_form(%{
      "id" => alias_record.id,
      "title" => alias_record.title,
      "kind" => alias_record.kind,
      "country_code" => alias_record.country_code,
      "language_code" => alias_record.language_code
    })
  end

  defp alias_form(params) do
    defaults = %{
      "id" => "",
      "title" => "",
      "kind" => "alternative",
      "country_code" => "",
      "language_code" => ""
    }

    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)
    to_form(Map.merge(defaults, params), as: :alias)
  end

  defp update_current_alias(series, id, params) do
    case current_manual_alias(series, id) do
      nil -> {:error, :not_manual_alias}
      alias_record -> Catalog.update_manual_alias(series, alias_record.id, params)
    end
  end

  defp current_manual_alias(series, id) do
    Enum.find(Catalog.list_title_aliases(series), &(&1.id == id and &1.precedence == :manual))
  end

  defp parse_alias_id(id) when is_integer(id), do: id

  defp parse_alias_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_alias_id(_id), do: nil

  defp alias_kind_options do
    [
      {gettext("Alternative"), "alternative"},
      {gettext("Native"), "native"},
      {gettext("Romaji"), "romaji"},
      {gettext("Licensed"), "licensed"},
      {gettext("Scene"), "scene"}
    ]
  end

  defp alias_kind_label(:alternative), do: gettext("Alternative")
  defp alias_kind_label(:native), do: gettext("Native")
  defp alias_kind_label(:romaji), do: gettext("Romaji")
  defp alias_kind_label(:licensed), do: gettext("Licensed")
  defp alias_kind_label(:scene), do: gettext("Scene")

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

  defp find_episode(series, id) do
    series.seasons |> Enum.flat_map(& &1.episodes) |> Enum.find(&(&1.id == id))
  end

  defp find_season(series, id), do: Enum.find(series.seasons, &(&1.id == id))

  defp all_monitored?(%{episodes: []}), do: false
  defp all_monitored?(%{episodes: eps}), do: Enum.all?(eps, & &1.monitored)

  # A season has something the search sweep would actually pick up. Gates the per-season
  # "Search all missing" and "Find a better match" controls; mirrors the per-episode "Search"
  # button.
  defp season_wanted?(%{episodes: episodes} = season, profile),
    do: Enum.any?(episodes, &episode_searchable?(&1, season, profile))

  # Eligibility lives in Catalog so the sweep and detail actions cannot drift.
  # Episodes arrive nested under their season rather than with the back-reference
  # preloaded; attaching that already-loaded parent is a pure in-memory operation.
  # The current profile summary is already assigned for the page, so passing it
  # through also keeps Auto's effective Standard semantics identical to the query.
  # No extra database query is needed while rendering the episode list.
  defp episode_searchable?(episode, season, profile),
    do: Catalog.episode_searchable?(%{episode | season: season}, profile)

  # The sweep hit its attempt cap and skips this episode — without a badge the row reads
  # "still trying" forever. The Search button next to it zeroes the counter and re-queues.
  # Delegates the park predicate to Catalog.episode_state/2 (the single derivation) so this
  # badge can't drift from the calendar's; episode_searchable? adds the monitored/specials
  # legs the state fn doesn't carry.
  defp search_exhausted?(episode, season, profile) do
    episode_searchable?(episode, season, profile) and
      Catalog.episode_state(episode) == :search_parked
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/library"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Library")}
      </.link>

      <div class="mb-4 flex flex-wrap items-center gap-2">
        <.button type="button" variant="neutral" size="sm" phx-click="edit_series">
          {gettext("Edit")}
        </.button>
        <.button type="button" variant="warning" size="sm" phx-click="ask_cancel_series">
          {gettext("Cancel series")}
        </.button>
        <.button type="button" variant="danger" size="sm" phx-click="ask_delete_series">
          {gettext("Delete series")}
        </.button>
      </div>

      <.form
        :if={@editing?}
        for={@form}
        id="series-form"
        phx-submit="save_series"
        class="mb-6 flex flex-wrap items-end gap-2"
      >
        <.input field={@form[:title]} type="text" label={gettext("Title")} />
        <.input field={@form[:year]} type="number" label={gettext("Year")} />
        <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
          {gettext("Save")}
        </.button>
        <.button variant="ghost" size="sm" type="button" phx-click="cancel_edit_series">
          {gettext("Cancel")}
        </.button>
      </.form>

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
          alt={@series.title}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div class="min-w-0 flex-1">
          <.header>
            {@series.title}
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

          <p :if={@series.overview} class="mt-3 max-w-prose text-sm leading-relaxed">
            {@series.overview}
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

      <div class="mb-4 grid max-w-2xl gap-3 sm:grid-cols-2">
        <form id="series-detail-language-form" phx-change="set_series_language">
          <.language_select value={@series.preferred_language} />
        </form>
        <div>
          <.form for={@profile_form} id="series-profile-form" phx-change="set_media_profile">
            <.profile_select field={@profile_form[:media_profile]} />
          </.form>
          <.profile_summary id="series-profile-summary" summary={@profile_summary} />
        </div>
      </div>

      <details class="mb-6 max-w-3xl">
        <summary class="cursor-pointer border-b border-base-300 pb-2 text-lg font-semibold">
          {gettext("Title aliases")}
        </summary>
        <p class="mb-2 mt-2 text-sm text-base-content/70">
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

      <details :if={@profile_summary.effective == :anime} class="mb-6 max-w-3xl">
        <summary
          class="cursor-pointer border-b border-base-300 pb-2 text-lg font-semibold"
          phx-click="load_episode_groups"
        >
          {gettext("Alternate numbering")}
        </summary>
        <p class="mb-2 mt-2 text-sm text-base-content/70">
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

      <.empty_state
        :if={@series.seasons == []}
        icon="hero-tv"
        title={gettext("No seasons found")}
        message={gettext("TMDB returned no season data for this series.")}
      />

      <details :for={season <- @series.seasons} class="mb-6">
        <summary class="cursor-pointer border-b border-base-300 pb-2">
          <span class="text-lg font-semibold">
            {season_label(season.season_number)}
            <span class="ml-2 text-sm font-normal text-base-content/70">
              {gettext("%{n}/%{m} monitored",
                n: monitored_count(season),
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
              :if={season_wanted?(season, @profile_summary)}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="tv_manual_search"
              phx-value-season={season.season_number}
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
                <span class="min-w-0 flex-1 truncate text-sm" title={ep.title}>{ep.title}</span>
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
                <.status_badge
                  :if={search_exhausted?(ep, season, @profile_summary)}
                  kind={:episode}
                  status={:search_parked}
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

  defp monitored_count(season), do: Enum.count(season.episodes, & &1.monitored)

  # "1080p · 2.1 GB" for a downloaded episode — drops whichever piece TMDB/import didn't capture.
  defp episode_file_info(ep) do
    [ep.imported_resolution, humanize_bytes(ep.imported_size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
