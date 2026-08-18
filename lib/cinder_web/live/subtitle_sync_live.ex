defmodule CinderWeb.SubtitleSyncLive do
  @moduledoc "Admin controls and textual previews for manifest-managed subtitle synchronization."
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Subtitles.Sync
  alias Cinder.Subtitles.Sync.{Timing, Worker}

  @impl true
  def mount(params, _session, socket) do
    scope = scope(params)

    if connected?(socket), do: Worker.subscribe()
    worker_status = Worker.status()

    {:ok,
     socket
     |> stream_configure(:items, dom_id: &"subtitle-sync-item-#{&1.id}")
     |> assign(
       page_title: gettext("Subtitle synchronization"),
       scope: scope,
       selected: nil,
       adjustment_form: adjustment_form(),
       preview: nil,
       worker_status: worker_status,
       seasons: seasons(scope),
       items_by_id: %{},
       scope_video_paths: MapSet.new(),
       items_loading: true,
       items_failed: false,
       seen_worker_result_count: worker_result_count(worker_status),
       pending_worker_results: %{},
       reload_after_load: false
     )
     |> stream(:items, [])
     |> load_items()}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) when is_binary(id) do
    case find_item(socket, id) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         assign(socket, selected: item, adjustment_form: adjustment_form(), preview: nil)}
    end
  end

  def handle_event("preview", %{"adjustment" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket,
       adjustment_form: to_form(params, as: :adjustment),
       preview: preview(params, socket.assigns.selected)
     )}
  end

  def handle_event("apply", %{"adjustment" => params}, %{assigns: %{selected: item}} = socket)
      when is_map(params) and not is_nil(item) do
    case adjustment(params, item, socket.assigns.preview, socket.assigns.scope) do
      {:ok, status, item} ->
        {:noreply,
         socket
         |> put_flash(:info, applied_message(status))
         |> put_item(item)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(adjustment_form: to_form(params, as: :adjustment), preview: nil)
         |> put_flash(:error, gettext("Enter a valid delay/rate or timestamp anchors."))}
    end
  end

  def handle_event("reset", %{"id" => id}, socket) when is_binary(id) do
    case Sync.reset_in_scope(socket.assigns.scope, id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Original subtitle restored."))
         |> refresh_items()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Original subtitle could not be restored."))}
    end
  end

  def handle_event("enqueue", _params, socket) do
    enqueue(socket.assigns.scope)
    {:noreply, put_flash(socket, :info, gettext("Subtitle analysis queued."))}
  end

  def handle_event("enqueue_season", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         true <- Enum.any?(socket.assigns.seasons, &(&1.id == id)) do
      Worker.enqueue_season(id)
      {:noreply, put_flash(socket, :info, gettext("Season subtitle analysis queued."))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:subtitle_sync_status, status}, socket) do
    {new_results, reload?} =
      new_worker_results(status, socket.assigns.seen_worker_result_count)

    {:noreply,
     socket
     |> assign(
       worker_status: status,
       seen_worker_result_count: worker_result_count(status)
     )
     |> merge_worker_results(new_results)
     |> reload_after_worker_status(reload?)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_items, {:ok, {items, scope_video_paths}}, socket) when is_list(items) do
    items_by_id = Map.new(items, &{&1.id, &1})
    selected_id = if socket.assigns.selected, do: socket.assigns.selected.id

    {known_results, unknown_results} =
      Enum.split_with(socket.assigns.pending_worker_results, fn {id, _result} ->
        Map.has_key?(items_by_id, id)
      end)

    reload? =
      socket.assigns.reload_after_load or
        unknown_results_in_scope?(
          unknown_results,
          socket.assigns.scope,
          scope_video_paths
        )

    socket =
      socket
      |> assign(
        items_by_id: items_by_id,
        scope_video_paths: scope_video_paths,
        items_loading: false,
        items_failed: false,
        selected: Map.get(items_by_id, selected_id),
        preview: nil,
        pending_worker_results: %{},
        reload_after_load: false
      )
      |> stream(:items, items, reset: true)
      |> apply_worker_results(Enum.map(known_results, &elem(&1, 1)))

    if reload?,
      do: {:noreply, load_items(socket)},
      else: {:noreply, socket}
  end

  def handle_async(:load_items, {:exit, _reason}, socket) do
    {:noreply, assign(socket, items_loading: false, items_failed: true)}
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
      <.link navigate={~p"/activity"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Activity")}
      </.link>

      <.header>
        {gettext("Subtitle synchronization")}
        <:subtitle>
          {gettext(
            "Cinder checks only OpenSubtitles sidecars. Embedded tracks are reference material and are never changed."
          )}
        </:subtitle>
        <:actions>
          <.button id="enqueue-subtitle-scope" type="button" size="sm" phx-click="enqueue">
            {gettext("Analyze this scope")}
          </.button>
        </:actions>
      </.header>

      <section class="mt-4 rounded-box bg-base-200 p-4" aria-live="polite">
        <div class="flex flex-wrap items-center gap-3">
          <span class="font-medium">{worker_label(@worker_status)}</span>
          <span class="text-sm text-base-content/70">
            {gettext("%{count} queued", count: @worker_status.queued)}
          </span>
          <span class="text-sm text-base-content/70">
            {gettext("%{aligned} aligned · %{corrected} corrected · %{review} review",
              aligned: @worker_status.counts.aligned,
              corrected: @worker_status.counts.corrected,
              review: @worker_status.counts.review + @worker_status.counts.failed
            )}
          </span>
        </div>
      </section>

      <section :if={@seasons != []} class="mt-6">
        <h2 class="font-semibold">{gettext("Seasons")}</h2>
        <div class="mt-2 flex flex-wrap gap-2">
          <.button
            :for={season <- @seasons}
            id={"enqueue-season-#{season.id}"}
            type="button"
            variant="neutral"
            size="sm"
            phx-click="enqueue_season"
            phx-value-id={season.id}
          >
            {gettext("Analyze season %{number}", number: season.season_number)}
          </.button>
        </div>
      </section>

      <section class="mt-8 grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,24rem)]">
        <div>
          <h2 class="pb-3 text-lg font-semibold">{gettext("Managed sidecars")}</h2>
          <p
            :if={@items_loading}
            id="subtitle-sync-loading"
            role="status"
            class="pb-3 text-sm text-base-content/70"
          >
            {gettext("Loading managed sidecars…")}
          </p>
          <p
            :if={@items_failed}
            id="subtitle-sync-load-error"
            role="alert"
            class="pb-3 text-sm text-error"
          >
            {gettext("Managed sidecars could not be loaded.")}
          </p>
          <ul id="subtitle-sync-items" phx-update="stream" class="space-y-2">
            <li
              :for={{dom_id, item} <- @streams.items}
              id={dom_id}
              class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-2"
            >
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium">{item.label}</p>
                <p class="text-xs text-base-content/70">
                  {sync_label(item)}
                </p>
              </div>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="select"
                phx-value-id={item.id}
              >
                {gettext("Adjust")}
              </.button>
              <.button
                :if={item.sync}
                id={"reset-subtitle-#{item.id}"}
                type="button"
                variant="ghost"
                size="sm"
                phx-click="reset"
                phx-value-id={item.id}
              >
                {gettext("Reset")}
              </.button>
            </li>
          </ul>
        </div>

        <aside :if={@selected} class="rounded-box border border-base-300 p-4">
          <h2 class="font-semibold">{gettext("Manual correction")}</h2>
          <p class="mt-1 text-sm text-base-content/70">{@selected.label}</p>
          <.form
            for={@adjustment_form}
            id="subtitle-sync-form"
            phx-change="preview"
            phx-submit="apply"
            class="mt-4 space-y-3"
          >
            <.input
              field={@adjustment_form[:mode]}
              type="select"
              label={gettext("Method")}
              options={[
                {gettext("Direct delay and rate"), "direct"},
                {gettext("Timestamp anchors"), "anchors"}
              ]}
            />
            <div :if={@adjustment_form[:mode].value != "anchors"} class="grid grid-cols-2 gap-2">
              <.input
                field={@adjustment_form[:delay_ms]}
                type="number"
                step="1"
                label={gettext("Delay (ms)")}
              />
              <.input
                field={@adjustment_form[:rate]}
                type="number"
                step="0.000001"
                min="0.000001"
                label={gettext("Rate")}
              />
            </div>
            <div :if={@adjustment_form[:mode].value == "anchors"} class="space-y-2">
              <p class="text-xs text-base-content/70">
                {gettext(
                  "Enter seconds from the sidecar and the matching video moment. The second pair is optional."
                )}
              </p>
              <div class="grid grid-cols-2 gap-2">
                <.input
                  field={@adjustment_form[:sidecar_1]}
                  type="number"
                  step="0.001"
                  label={gettext("Sidecar 1 (s)")}
                />
                <.input
                  field={@adjustment_form[:video_1]}
                  type="number"
                  step="0.001"
                  label={gettext("Video 1 (s)")}
                />
                <.input
                  field={@adjustment_form[:sidecar_2]}
                  type="number"
                  step="0.001"
                  label={gettext("Sidecar 2 (s)")}
                />
                <.input
                  field={@adjustment_form[:video_2]}
                  type="number"
                  step="0.001"
                  label={gettext("Video 2 (s)")}
                />
              </div>
            </div>
            <p :if={@preview} id="subtitle-sync-preview" class="text-sm tabular-nums">
              {@preview.text}
            </p>
            <.button type="submit" size="sm">{gettext("Apply correction")}</.button>
          </.form>
        </aside>
      </section>
    </Layouts.app>
    """
  end

  defp scope(params) do
    Enum.find_value([:movie, :episode, :season, :series], :library, fn kind ->
      case Integer.parse(Map.get(params, Atom.to_string(kind), "")) do
        {id, ""} when id > 0 -> {kind, id}
        _ -> nil
      end
    end)
  end

  defp seasons({:series, id}) do
    case Catalog.get_series_with_tree(id) do
      nil -> []
      series -> series.seasons
    end
  end

  defp seasons(_scope), do: []

  defp find_item(socket, id), do: Map.get(socket.assigns.items_by_id, id)

  defp adjustment(params, item, preview, scope) do
    with {:ok, transform} <- normalized_adjustment(params),
         %{} <- item,
         %{item_id: item_id, fingerprint: fingerprint, transform: ^transform} <- preview,
         true <- item_id == item.id do
      {offset_ms, rate} = transform
      Sync.manual_in_scope(scope, item.id, offset_ms, rate, fingerprint)
    else
      _ -> {:error, :preview_required}
    end
  end

  defp preview(_params, nil), do: nil

  defp preview(params, item) do
    with {:ok, {offset_ms, rate} = transform} <- normalized_adjustment(params),
         {:ok, fingerprint} <- Sync.fingerprint(item) do
      %{
        item_id: item.id,
        fingerprint: fingerprint,
        transform: transform,
        text: preview_text(offset_ms, rate)
      }
    else
      _ -> nil
    end
  end

  defp normalized_adjustment(params) do
    case parse_adjustment(params) do
      {:direct, offset_ms, rate} -> {:ok, {offset_ms, rate}}
      {:anchors, anchors} -> Timing.from_anchors(anchors)
      :error -> {:error, :invalid_adjustment}
    end
  end

  defp parse_adjustment(%{"mode" => "anchors"} = params) do
    with {:ok, first} <- anchor(params["sidecar_1"], params["video_1"]),
         {:ok, second} <- optional_anchor(params["sidecar_2"], params["video_2"]) do
      {:anchors, [first | List.wrap(second)]}
    else
      _ -> :error
    end
  end

  defp parse_adjustment(params) do
    with {delay, ""} <- Integer.parse(params["delay_ms"] || ""),
         {rate, ""} <- Float.parse(params["rate"] || ""),
         true <- Timing.valid_adjustment?(delay, rate) do
      {:direct, delay, rate}
    else
      _ -> :error
    end
  end

  defp anchor(sidecar, video) do
    with {:ok, sidecar} <- milliseconds(sidecar),
         {:ok, video} <- milliseconds(video),
         do: {:ok, {sidecar, video}}
  end

  defp optional_anchor(sidecar, video) when sidecar in [nil, ""] and video in [nil, ""],
    do: {:ok, nil}

  defp optional_anchor(sidecar, video), do: anchor(sidecar, video)

  defp milliseconds(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 and seconds <= 604_800 ->
        {:ok, round(seconds * 1_000)}

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  defp milliseconds(_value), do: {:error, :invalid_timestamp}

  defp adjustment_form do
    to_form(
      %{
        "mode" => "direct",
        "delay_ms" => "0",
        "rate" => "1.0",
        "sidecar_1" => "",
        "video_1" => "",
        "sidecar_2" => "",
        "video_2" => ""
      },
      as: :adjustment
    )
  end

  defp refresh_items(socket) do
    load_items(socket)
  end

  defp load_items(socket) do
    scope = socket.assigns.scope

    socket
    |> assign(items_loading: true, items_failed: false)
    |> start_async(:load_items, fn ->
      units = Sync.units(scope)

      {
        Enum.flat_map(units, &Sync.discover(&1.video_path)),
        MapSet.new(units, & &1.video_path)
      }
    end)
  end

  defp latest_results(results) do
    Enum.reduce(results, %{}, fn
      %{id: id} = result, latest when is_binary(id) -> Map.put_new(latest, id, result)
      _result, latest -> latest
    end)
  end

  defp new_worker_results(status, seen_count) do
    count = worker_result_count(status)
    delta = count - seen_count

    cond do
      delta <= 0 -> {%{}, false}
      delta > length(status.recent) -> {%{}, true}
      true -> {status.recent |> Enum.take(delta) |> latest_results(), false}
    end
  end

  defp worker_result_count(status), do: status.counts |> Map.values() |> Enum.sum()

  defp merge_worker_results(socket, results) when map_size(results) == 0, do: socket

  defp merge_worker_results(%{assigns: %{items_loading: true}} = socket, results) do
    socket
    |> assign(pending_worker_results: Map.merge(socket.assigns.pending_worker_results, results))
    |> apply_worker_results(Map.values(results))
  end

  defp merge_worker_results(socket, results) do
    {known_results, unknown_results} =
      Enum.split_with(results, fn {id, _result} ->
        Map.has_key?(socket.assigns.items_by_id, id)
      end)

    socket =
      apply_worker_results(socket, Enum.map(known_results, &elem(&1, 1)))

    if unknown_results_in_scope?(
         unknown_results,
         socket.assigns.scope,
         socket.assigns.scope_video_paths
       ),
       do: load_items(socket),
       else: socket
  end

  defp reload_after_worker_status(socket, false), do: socket

  defp reload_after_worker_status(%{assigns: %{items_loading: true}} = socket, true),
    do: assign(socket, reload_after_load: true)

  defp reload_after_worker_status(socket, true), do: load_items(socket)

  defp unknown_results_in_scope?(results, scope, known_paths) do
    (scope == :library and results != []) or
      Enum.any?(results, fn {_id, result} ->
        MapSet.member?(known_paths, Map.get(result, :video_path)) or
          scope in Map.get(result, :scopes, MapSet.new())
      end)
  end

  defp apply_worker_results(socket, results) do
    Enum.reduce(results, socket, fn result, socket ->
      case {Map.get(socket.assigns.items_by_id, Map.get(result, :id)), Map.get(result, :status)} do
        {%{} = item, status} when status in [:aligned, :corrected, :review] ->
          sync = Map.take(result, [:method, :offset_ms, :rate, :reason])

          item = %{
            item
            | sync: Map.put(sync, :status, Atom.to_string(status)),
              review_reason: nil
          }

          put_item(socket, item)

        _ ->
          socket
      end
    end)
  end

  defp put_item(socket, item) do
    selected =
      if socket.assigns.selected && socket.assigns.selected.id == item.id,
        do: item,
        else: socket.assigns.selected

    socket
    |> assign(
      items_by_id: Map.put(socket.assigns.items_by_id, item.id, item),
      selected: selected,
      preview: nil
    )
    |> stream_insert(:items, item)
  end

  defp enqueue(:library), do: Worker.enqueue_library()
  defp enqueue({:movie, id}), do: Worker.enqueue_movie(id)
  defp enqueue({:series, id}), do: Worker.enqueue_series(id)
  defp enqueue({:season, id}), do: Worker.enqueue_season(id)
  defp enqueue({:episode, id}), do: Worker.enqueue_episode(id)

  defp preview_text(offset_ms, rate) do
    gettext("Delay %{delay} s · rate %{rate} · drift %{drift}%",
      delay: :erlang.float_to_binary(offset_ms / 1_000, decimals: 3),
      rate: :erlang.float_to_binary(rate * 1.0, decimals: 6),
      drift: :erlang.float_to_binary((rate - 1) * 100, decimals: 3)
    )
  end

  defp applied_message(:aligned),
    do: gettext("Subtitle was already aligned; the file was not rewritten.")

  defp applied_message(:corrected), do: gettext("Subtitle correction applied.")

  defp worker_label(%{state: :running, current: current}) when not is_nil(current),
    do: gettext("Analyzing %{label}", label: current.label)

  defp worker_label(_status), do: gettext("Worker idle")

  defp sync_label(%{review_reason: reason}) when is_binary(reason),
    do: sync_label(%{status: "review", reason: reason})

  defp sync_label(%{sync: sync}), do: sync_label(sync)
  defp sync_label(nil), do: gettext("Not analyzed")

  defp sync_label(%{status: "review", reason: reason}),
    do: gettext("Needs review: %{reason}", reason: reason || gettext("low confidence"))

  defp sync_label(%{method: method, offset_ms: offset, rate: rate}),
    do:
      gettext("Aligned via %{method}: %{delay} ms, rate %{rate}",
        method: method,
        delay: offset,
        rate: :erlang.float_to_binary(rate * 1.0, decimals: 6)
      )
end
