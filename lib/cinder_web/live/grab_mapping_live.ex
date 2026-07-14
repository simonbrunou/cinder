defmodule CinderWeb.GrabMappingLive do
  @moduledoc "Admin mapping-recovery ledger for one held anime grab."
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {id, ""} <- Integer.parse(id),
         %Grab{mapping_status: :needs_mapping} = grab <- Catalog.get_mapping_grab(id) do
      if connected?(socket), do: Catalog.subscribe_series()

      {:ok, assign_mapping(socket, grab)}
    else
      _ -> {:ok, stale_mapping(socket)}
    end
  end

  @impl true
  def handle_event("validate", %{"mapping" => attrs}, socket) do
    case form_mapping(attrs) do
      {:ok, mapping} -> {:noreply, assign_form(socket, mapping, nil)}
      {:error, _reason} -> {:noreply, mapping_error(socket)}
    end
  end

  def handle_event("save_and_retry", %{"mapping" => attrs}, socket) do
    with %Grab{mapping_status: :needs_mapping} = grab <-
           Catalog.get_mapping_grab(socket.assigns.grab.id),
         {:ok, normalized} <- normalize_mapping(attrs),
         {:ok, _grab} <- Catalog.resume_grab_mapping(grab, normalized) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Mapping saved. Import will retry shortly."))
       |> push_navigate(to: ~p"/activity")}
    else
      _failure -> {:noreply, mapping_error(socket)}
    end
  end

  def handle_event("promote", params, socket) do
    with %Grab{mapping_status: :needs_mapping} = grab <-
           Catalog.get_mapping_grab(socket.assigns.grab.id),
         {:ok, promotion} <- promotion(params, socket.assigns.mapping),
         {:ok, _coordinate} <- Catalog.promote_grab_mapping(grab, promotion) do
      {:noreply,
       socket
       |> assign(:promotion_status, gettext("Coordinate saved for future releases."))
       |> put_flash(:info, gettext("Coordinate saved for future releases."))}
    else
      _failure ->
        {:noreply,
         socket
         |> assign(:promotion_status, nil)
         |> put_flash(:error, gettext("That coordinate cannot be promoted."))}
    end
  end

  def handle_event("ask_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirming_cancel?, true)}

  def handle_event("dismiss_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirming_cancel?, false)}

  def handle_event("confirm_cancel", _params, socket) do
    case Catalog.cancel_mapping_grab(socket.assigns.grab) do
      {:ok, _deleted} ->
        {:noreply, push_navigate(socket, to: ~p"/activity")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirming_cancel?, false)
         |> put_flash(:error, gettext("The download could not be cancelled."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:series_updated, series_id}, socket) do
    if series_id == socket.assigns.series.id do
      case Catalog.get_mapping_grab(socket.assigns.grab.id) do
        %Grab{mapping_status: :needs_mapping} = grab ->
          {:noreply, refresh_mapping_evidence(socket, grab)}

        _ ->
          {:noreply, stale_mapping(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_mapping(socket, grab) do
    mapping = mapping_attrs(grab)

    socket
    |> assign(
      grab: grab,
      series: grab_series(grab),
      confirming_cancel?: false,
      promotion_status: nil,
      form_error: nil
    )
    |> assign_form(mapping, nil)
    |> refresh_mapping_evidence(grab)
  end

  defp refresh_mapping_evidence(socket, grab) do
    series = grab_series(grab)

    assign(socket,
      grab: grab,
      series: series,
      episode_options: episode_options(Catalog.get_series_with_tree(series.id), grab.id)
    )
  end

  defp assign_form(socket, mapping, error) do
    assign(socket,
      mapping: mapping,
      form: to_form(mapping, as: :mapping),
      form_error: error
    )
  end

  defp mapping_error(socket) do
    message = gettext("The mapping could not be saved.")
    socket |> assign(:form_error, message) |> put_flash(:error, message)
  end

  defp stale_mapping(socket) do
    socket
    |> put_flash(:error, gettext("That mapping no longer needs attention."))
    |> push_navigate(to: ~p"/activity")
  end

  defp mapping_attrs(grab) do
    %{
      "files" =>
        grab.automatic_mapping_decisions
        |> decision_files()
        |> Enum.map(fn decision ->
          %{
            "relative_path" => decision["relative_path"],
            "action" => if(decision["ignored"], do: "ignore", else: "assign"),
            "episode_ids" => Enum.map(decision["episode_ids"] || [], &to_string/1)
          }
        end),
      "target_episode_ids" => Enum.map(grab.episodes, &to_string(&1.id)),
      "monitor_episode_ids" => []
    }
  end

  defp form_mapping(attrs) when is_map(attrs) do
    with {:ok, files} <- form_files(attrs["files"]),
         {:ok, targets} <- form_ids(attrs["target_episode_ids"]),
         {:ok, monitors} <- form_ids(attrs["monitor_episode_ids"]) do
      {:ok,
       %{
         "files" => files,
         "target_episode_ids" => targets,
         "monitor_episode_ids" => monitors
       }}
    end
  end

  defp form_mapping(_attrs), do: {:error, :invalid_mapping}

  defp form_files(files) do
    with {:ok, files} <- indexed_values(files) do
      reduce_form_files(files)
    end
  end

  defp reduce_form_files(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, normalized} ->
      reduce_form_file(file, normalized)
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp reduce_form_file(file, normalized) do
    case form_file(file) do
      {:ok, value} -> {:cont, {:ok, [value | normalized]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp form_file(%{"relative_path" => path, "action" => action} = file)
       when is_binary(path) and path != "" and action in ["assign", "ignore"] do
    with {:ok, episode_ids} <- form_ids(file["episode_ids"]) do
      {:ok,
       %{
         "relative_path" => path,
         "action" => action,
         "episode_ids" => if(action == "assign", do: episode_ids, else: [])
       }}
    end
  end

  defp form_file(_file), do: {:error, :invalid_file}

  defp form_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, normalized} ->
      case positive_id(id) do
        {:ok, value} -> {:cont, {:ok, [to_string(value) | normalized]}}
        :error -> {:halt, {:error, :invalid_id}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_mapping(attrs) do
    with {:ok, mapping} <- form_mapping(attrs),
         {:ok, files} <- normalize_files(mapping["files"]),
         {:ok, target_ids} <- normalize_ids(mapping["target_episode_ids"]),
         {:ok, monitor_ids} <- normalize_ids(mapping["monitor_episode_ids"]) do
      {:ok,
       %{
         "files" => files,
         "target_episode_ids" => target_ids,
         "monitor_episode_ids" => monitor_ids
       }}
    end
  end

  defp normalize_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, normalized} ->
      case normalize_file(file) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_file(%{"relative_path" => path, "action" => "assign", "episode_ids" => ids}) do
    with {:ok, ids} <- normalize_ids(ids) do
      {:ok, %{"relative_path" => path, "action" => "assign", "episode_ids" => ids}}
    end
  end

  defp normalize_file(%{"relative_path" => path, "action" => "ignore"}),
    do: {:ok, %{"relative_path" => path, "action" => "ignore"}}

  defp normalize_file(_file), do: {:error, :invalid_file}

  defp normalize_ids(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, normalized} ->
      case positive_id(id) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        :error -> {:halt, {:error, :invalid_id}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_ids(_ids), do: {:error, :invalid_ids}

  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp positive_id(_id), do: :error

  defp indexed_values(values) when is_list(values), do: {:ok, values}

  defp indexed_values(values) when is_map(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn {index, value}, {:ok, indexed} ->
      case Integer.parse(index) do
        {index, ""} when index >= 0 -> {:cont, {:ok, [{index, value} | indexed]}}
        _ -> {:halt, {:error, :invalid_index}}
      end
    end)
    |> case do
      {:ok, indexed} -> {:ok, indexed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      error -> error
    end
  end

  defp indexed_values(_values), do: {:error, :invalid_files}

  defp promotion(
         %{"relative_path" => path, "scheme" => scheme, "value" => value},
         %{"files" => files}
       )
       when is_binary(path) and is_binary(scheme) and is_binary(value) do
    with %{"action" => "assign", "episode_ids" => ids} <-
           Enum.find(files, &(&1["relative_path"] == path)),
         {:ok, ids} <- normalize_ids(ids),
         true <- ids != [] do
      {:ok,
       %{
         "relative_path" => path,
         "scheme" => scheme,
         "value" => value,
         "episode_ids" => ids
       }}
    else
      _ -> {:error, :invalid_promotion}
    end
  end

  defp promotion(_params, _mapping), do: {:error, :invalid_promotion}

  defp grab_series(%Grab{episodes: [episode | _]}), do: episode.season.series

  defp episode_options(series, grab_id) do
    series.seasons
    |> Enum.flat_map(fn season -> Enum.map(season.episodes, &{season, &1}) end)
    |> Enum.filter(fn {_season, episode} ->
      is_nil(episode.file_path) and (is_nil(episode.grab_id) or episode.grab_id == grab_id)
    end)
  end

  defp decision_files(%{"files" => files}) when is_list(files), do: files
  defp decision_files(_decisions), do: []

  defp form_file_at(mapping, index), do: Enum.at(mapping["files"], index, %{})

  defp selected?(mapping, key, id), do: to_string(id) in (mapping[key] || [])

  defp file_selected?(mapping, index, id),
    do: to_string(id) in (form_file_at(mapping, index)["episode_ids"] || [])

  defp file_action(mapping, index), do: form_file_at(mapping, index)["action"]

  defp episode_label(season, episode),
    do:
      "#{Episode.code(season.season_number, episode.episode_number)} · #{episode.title || gettext("Untitled")}"

  defp coordinate_label(%{"scheme" => scheme, "values" => values}) when is_list(values),
    do: "#{scheme_label(scheme)} #{Enum.join(values, ", ")}"

  defp coordinate_label(_coordinate), do: gettext("Unknown coordinate")

  defp resolution_coordinate_label(resolution),
    do: "#{scheme_label(resolution["scheme"])} #{resolution["canonical_value"]}"

  defp promotion_values(decision) do
    for {coordinate, coordinate_index} <-
          Enum.with_index(get_in(decision, ["parsed", "coordinates"]) || []),
        {value, value_index} <- Enum.with_index(coordinate["values"] || []),
        do: {coordinate, value, coordinate_index, value_index}
  end

  defp evidence_resolution(decision), do: get_in(decision, ["evidence", "resolution"])

  defp evidence_resolutions(decision) do
    case get_in(decision, ["evidence", "resolutions"]) do
      resolutions when is_list(resolutions) -> resolutions
      _ -> []
    end
  end

  defp resolution_candidate_sets(resolution) do
    resolution
    |> Map.get("candidates", [])
    |> Enum.filter(&is_list/1)
  end

  defp resolution_matches(resolution) do
    case get_in(resolution, ["resolver", "matches"]) do
      matches when is_list(matches) -> matches
      _ -> []
    end
  end

  defp resolution_precedence(resolution),
    do: get_in(resolution, ["resolver", "precedence"])

  defp decision_candidate_ids(decision) do
    nested_ids =
      Enum.flat_map(evidence_resolutions(decision), fn resolution ->
        (resolution["episode_ids"] || []) ++ List.flatten(resolution_candidate_sets(resolution))
      end)

    ((decision["episode_ids"] || []) ++ nested_ids)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp issue_candidate_ids(%{"candidate_episode_ids" => ids}) when is_list(ids), do: ids
  defp issue_candidate_ids(_issue), do: []

  defp safe_provenance_value(value) when is_binary(value) do
    if Path.type(value) == :absolute, do: gettext("Hidden"), else: value
  end

  defp safe_provenance_value(_value), do: gettext("Unknown")

  defp scheme_label("absolute"), do: gettext("Absolute")
  defp scheme_label("standard"), do: gettext("Standard")
  defp scheme_label("scene"), do: gettext("Scene")
  defp scheme_label("combined"), do: gettext("Combined")
  defp scheme_label("typed_special"), do: gettext("Typed special")
  defp scheme_label(_scheme), do: gettext("Unknown")

  defp role_label("story"), do: gettext("Story")
  defp role_label("main"), do: gettext("Story")
  defp role_label("extra"), do: gettext("Extra")
  defp role_label("unknown"), do: gettext("Unknown")
  defp role_label(_role), do: gettext("Unknown")

  defp source_label("automatic"), do: gettext("Automatic")
  defp source_label("manual"), do: gettext("Manual")
  defp source_label(_source), do: gettext("Unknown")

  defp resolution_label("ambiguous"), do: gettext("Ambiguous")
  defp resolution_label("unmatched"), do: gettext("Unmatched")
  defp resolution_label(_resolution), do: gettext("Unknown")

  defp precedence_label("manual"), do: gettext("Manual")
  defp precedence_label("curated"), do: gettext("Curated")
  defp precedence_label("inferred"), do: gettext("Inferred")
  defp precedence_label(_precedence), do: gettext("Unknown")

  defp issue_label("unresolved_file"), do: gettext("Unresolved file")
  defp issue_label("outside_authoritative_set"), do: gettext("Outside authoritative set")
  defp issue_label("duplicate_episode_assignment"), do: gettext("Duplicate episode assignment")
  defp issue_label("missing_episode_assignment"), do: gettext("Missing episode assignment")
  defp issue_label("stale_override"), do: gettext("Stale override")
  defp issue_label(_reason), do: gettext("Unknown mapping issue")

  defp current_ids(grab), do: Enum.map(grab.episodes, & &1.id)

  defp parsed_form_ids(mapping, key) do
    mapping[key]
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case positive_id(id) do
        {:ok, value} -> [value]
        :error -> []
      end
    end)
  end

  defp target_delta(mapping, grab) do
    targets = parsed_form_ids(mapping, "target_episode_ids")
    current = current_ids(grab)

    %{
      additions: targets -- current,
      removals: current -- targets,
      monitors: parsed_form_ids(mapping, "monitor_episode_ids")
    }
  end

  defp delta_label([]), do: gettext("None")
  defp delta_label(ids), do: Enum.join(ids, ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/activity"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Activity")}
      </.link>

      <.header>
        {gettext("Review mapping")}
        <:subtitle>{@series.title}</:subtitle>
      </.header>

      <section id="mapping-release" class="rounded-box bg-base-200/50 p-4">
        <h2 class="font-semibold">{gettext("Release")}</h2>
        <p class="break-words">{@grab.mapping_snapshot["release"]["title"]}</p>
        <p
          :for={coordinate <- @grab.mapping_snapshot["release"]["coordinates"] || []}
          class="text-sm text-base-content/70"
        >
          {coordinate_label(coordinate)}
        </p>
      </section>

      <div class="mt-4 grid gap-4 sm:grid-cols-2">
        <section id="mapping-original-targets" class="rounded-box border border-base-300 p-4">
          <h2 class="font-semibold">{gettext("Original reserved episode IDs")}</h2>
          <p>{delta_label(@grab.mapping_snapshot["reserved_episode_ids"] || [])}</p>
        </section>
        <section id="mapping-current-targets" class="rounded-box border border-base-300 p-4">
          <h2 class="font-semibold">{gettext("Current linked episodes")}</h2>
          <p>
            {Enum.map_join(@grab.episodes, ", ", fn episode ->
              Episode.code(episode.season.season_number, episode.episode_number)
            end)}
          </p>
        </section>
      </div>

      <section
        :if={is_map(@grab.mapping_issue)}
        id="mapping-issue"
        class="mt-4 rounded-box border border-warning/40 bg-warning/10 p-4"
      >
        <h2 class="font-semibold">{gettext("Blocking reason")}</h2>
        <p>{issue_label(@grab.mapping_issue["reason"])}</p>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext("Candidates: %{ids}",
            ids:
              Enum.map_join(
                issue_candidate_ids(@grab.mapping_issue),
                ", ",
                &gettext("candidate %{id}", id: &1)
              )
          )}
        </p>
      </section>

      <.form
        for={@form}
        id="mapping-form"
        phx-change="validate"
        phx-submit="save_and_retry"
        class="mt-6 space-y-6"
      >
        <p :if={@form_error} id="mapping-form-error" class="text-sm text-error" role="alert">
          {@form_error}
        </p>

        <section
          :for={
            {decision, index} <- Enum.with_index(decision_files(@grab.automatic_mapping_decisions))
          }
          id={"mapping-file-#{index}"}
          class="rounded-box border border-base-300 p-4"
        >
          <.input
            type="hidden"
            name={"mapping[files][#{index}][relative_path]"}
            value={decision["relative_path"]}
          />
          <h2 class="break-words font-semibold">{decision["relative_path"]}</h2>
          <p class="mt-1 text-xs text-base-content/70">
            {gettext("%{size} bytes · device %{device} · inode %{inode} · mtime %{mtime}",
              size: decision["size"],
              device: decision["major_device"],
              inode: decision["inode"],
              mtime: decision["mtime"]
            )}
          </p>
          <p class="mt-2 text-sm">
            {gettext("Role: %{role}",
              role: role_label(get_in(decision, ["parsed", "role"]) || "unknown")
            )}
            <span :if={get_in(decision, ["parsed", "group"])}>
              · {gettext("Group: %{group}", group: get_in(decision, ["parsed", "group"]))}
            </span>
          </p>
          <p id={"mapping-file-#{index}-source"} class="mt-1 text-sm text-base-content/70">
            {gettext("Source: %{source}", source: source_label(decision["source"]))}
          </p>
          <div class="mt-2 flex flex-wrap gap-2">
            <span
              :for={coordinate <- get_in(decision, ["parsed", "coordinates"]) || []}
              class="badge badge-outline badge-sm"
            >
              {coordinate_label(coordinate)}
            </span>
          </div>
          <p class="mt-2 text-sm text-base-content/70">
            {gettext("Candidates: %{ids}",
              ids:
                Enum.map_join(
                  decision_candidate_ids(decision),
                  ", ",
                  &gettext("candidate %{id}", id: &1)
                )
            )}
          </p>
          <div
            :if={evidence_resolution(decision) || evidence_resolutions(decision) != []}
            class="mt-1 space-y-1 text-xs text-base-content/70"
          >
            <p :if={evidence_resolution(decision)} data-resolution>
              {gettext("Resolution: %{resolution}",
                resolution: resolution_label(evidence_resolution(decision))
              )}
            </p>
            <div
              :for={resolution <- evidence_resolutions(decision)}
              class="rounded border border-base-300/70 p-2"
            >
              <p>{resolution_coordinate_label(resolution)}</p>
              <p :if={(resolution["episode_ids"] || []) != []}>
                {gettext("Episode IDs: %{ids}", ids: delta_label(resolution["episode_ids"]))}
              </p>
              <p
                :for={candidate_set <- resolution_candidate_sets(resolution)}
                data-candidate-set
              >
                {gettext("Candidate set: %{ids}", ids: delta_label(candidate_set))}
              </p>
              <div
                :if={resolution_precedence(resolution) || resolution_matches(resolution) != []}
                data-provenance
                class="mt-1"
              >
                <p :if={resolution_precedence(resolution)}>
                  {gettext("Precedence: %{precedence}",
                    precedence: precedence_label(resolution_precedence(resolution))
                  )}
                </p>
                <p :for={match <- resolution_matches(resolution)}>
                  {gettext("Source: %{source}",
                    source: safe_provenance_value(get_in(match, ["coordinate", "source"]))
                  )} · {gettext("Namespace: %{namespace}",
                    namespace: safe_provenance_value(get_in(match, ["coordinate", "namespace"]))
                  )} · {scheme_label(get_in(match, ["coordinate", "scheme"]))}
                  {safe_provenance_value(
                    get_in(match, ["coordinate", "canonical_value"]) ||
                      get_in(match, ["coordinate", "value"])
                  )} · {gettext("Episode IDs: %{ids}", ids: delta_label(match["episode_ids"] || []))}
                </p>
              </div>
            </div>
          </div>

          <fieldset class="mt-4">
            <legend class="font-medium">{gettext("File action")}</legend>
            <label
              for={"mapping-file-#{index}-assign"}
              class="mt-2 flex cursor-pointer items-center gap-2"
            >
              <input
                id={"mapping-file-#{index}-assign"}
                type="radio"
                class="radio radio-sm"
                name={"mapping[files][#{index}][action]"}
                value="assign"
                checked={file_action(@mapping, index) == "assign"}
              />
              {gettext("Assign")}
            </label>
            <div class="ml-6 mt-2 grid gap-1 sm:grid-cols-2">
              <label
                :for={{season, episode} <- @episode_options}
                for={"mapping-file-#{index}-episode-#{episode.id}"}
                class="flex cursor-pointer items-center gap-2 text-sm"
              >
                <input
                  id={"mapping-file-#{index}-episode-#{episode.id}"}
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name={"mapping[files][#{index}][episode_ids][]"}
                  value={episode.id}
                  checked={file_selected?(@mapping, index, episode.id)}
                />
                {episode_label(season, episode)}
              </label>
            </div>
            <label
              for={"mapping-file-#{index}-ignore"}
              class="mt-3 flex cursor-pointer items-center gap-2"
            >
              <input
                id={"mapping-file-#{index}-ignore"}
                type="radio"
                class="radio radio-sm"
                name={"mapping[files][#{index}][action]"}
                value="ignore"
                checked={file_action(@mapping, index) == "ignore"}
              />
              {gettext("Ignore as extra")}
            </label>
          </fieldset>

          <div :if={promotion_values(decision) != []} class="mt-4 flex flex-wrap gap-2">
            <.button
              :for={{coordinate, value, coordinate_index, value_index} <- promotion_values(decision)}
              id={"promote-coordinate-#{index}-#{coordinate_index}-#{value_index}"}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="promote"
              phx-value-relative_path={decision["relative_path"]}
              phx-value-scheme={coordinate["scheme"]}
              phx-value-value={value}
            >
              {gettext("Promote %{coordinate}",
                coordinate: "#{scheme_label(coordinate["scheme"])} #{value}"
              )}
            </.button>
          </div>
        </section>

        <section class="rounded-box border border-base-300 p-4">
          <h2 class="font-semibold">{gettext("Target episodes")}</h2>
          <div class="mt-2 grid gap-2 sm:grid-cols-2">
            <div :for={{season, episode} <- @episode_options}>
              <label
                for={"mapping-target-episode-#{episode.id}"}
                class="flex cursor-pointer items-center gap-2 text-sm"
              >
                <input
                  id={"mapping-target-episode-#{episode.id}"}
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name="mapping[target_episode_ids][]"
                  value={episode.id}
                  checked={selected?(@mapping, "target_episode_ids", episode.id)}
                />
                {episode_label(season, episode)}
              </label>
              <label
                :if={!episode.monitored}
                for={"mapping-monitor-episode-#{episode.id}"}
                class="ml-6 mt-1 flex cursor-pointer items-center gap-2 text-xs"
              >
                <input
                  id={"mapping-monitor-episode-#{episode.id}"}
                  type="checkbox"
                  class="checkbox checkbox-xs"
                  name="mapping[monitor_episode_ids][]"
                  value={episode.id}
                  checked={selected?(@mapping, "monitor_episode_ids", episode.id)}
                />
                {gettext("Also monitor this episode")}
              </label>
            </div>
          </div>
        </section>

        <section id="mapping-target-delta" class="rounded-box bg-base-200/50 p-4 text-sm">
          <h2 class="font-semibold">{gettext("Target changes")}</h2>
          <% delta = target_delta(@mapping, @grab) %>
          <p>{gettext("Additions: %{ids}", ids: delta_label(delta.additions))}</p>
          <p>{gettext("Removals: %{ids}", ids: delta_label(delta.removals))}</p>
          <p>{gettext("Monitor opt-ins: %{ids}", ids: delta_label(delta.monitors))}</p>
        </section>

        <div class="flex flex-wrap gap-2">
          <.button type="submit" variant="primary" phx-disable-with={gettext("Saving…")}>
            {gettext("Save and retry")}
          </.button>
          <.button
            id="ask-cancel-mapping"
            type="button"
            variant="danger"
            phx-click="ask_cancel"
          >
            {gettext("Cancel download")}
          </.button>
        </div>
      </.form>

      <p
        :if={@promotion_status}
        id="mapping-promotion-status"
        class="mt-4 text-sm text-success"
        role="status"
      >
        {@promotion_status}
      </p>

      <.confirm_action
        :if={@confirming_cancel?}
        id="confirm-cancel-mapping"
        class="mt-4"
        on_confirm="confirm_cancel"
        on_cancel="dismiss_cancel"
        confirm_label={gettext("Cancel download")}
        variant="warning"
      >
        <:caveat>
          {gettext("Cancel this download? Its episodes will return to the wanted queue.")}
        </:caveat>
      </.confirm_action>
    </Layouts.app>
    """
  end
end
