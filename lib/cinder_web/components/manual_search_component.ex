defmodule CinderWeb.ManualSearchComponent do
  @moduledoc """
  Interactive manual-search panel, shared by the movie and TV views. Queries the indexer
  asynchronously and lists every release with its scorer verdict, letting the user grab any one
  (overriding the band/blocklist for selection). Grabs are forwarded to the parent LiveView, which
  owns the Catalog writes, via `send(self(), {:manual_grab, mode, target, release})`. For an
  `:available` movie target a "Replace current file?" confirm gates the grab. An empty result
  shows "No releases found." (the parent only offers manual search for seasons with wanted
  episodes, so a fully-present season never opens the panel).

  Required assigns: `id`, `mode` (`:movie | :tv`), `target` (the `%Movie{}` or `%Series{}`), plus
  `season_number` for `:tv`. A `results:` assign (a list of `{release, verdict}` tuples) is
  consumed directly and skips the async fetch — useful for tests.
  """
  use CinderWeb, :live_component

  alias Cinder.{Acquisition, Download}

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> assign_new(:confirming, fn -> nil end)

    socket =
      cond do
        # Test / pre-seeded path: results supplied directly, skip the async fetch.
        preseeded?(assigns) ->
          assign(socket, :state, :loaded)

        # Already initialised (a parent re-render) — keep state/results/confirming as they are.
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

  defp start_search(socket) do
    %{mode: mode, target: target} = socket.assigns
    season = socket.assigns[:season_number]
    opts = [protocols: Download.available_protocols()]

    start_async(socket, :search, fn ->
      case mode do
        :movie -> Acquisition.list_releases(target.imdb_id, opts)
        :tv -> Acquisition.list_releases_tv(target, season, opts)
      end
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
          <span :if={release.language} class="badge badge-ghost badge-xs">{release.language}</span>
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

  # An :available movie grab routes through the replace-confirm; everything else grabs directly.
  defp grab_click(:movie, %{status: :available}, _release), do: "ask_replace"
  defp grab_click(_mode, _target, _release), do: "grab"

  # :wrong_protocol means no configured client — can't grab. Everything else the user may override.
  defp grabbable?({:rejected, :wrong_protocol}), do: false
  defp grabbable?(_), do: true

  defp verdict_reason({:rejected, :out_of_band}), do: gettext("outside size band")
  defp verdict_reason({:rejected, :blocklisted}), do: gettext("blocklisted")
  defp verdict_reason({:rejected, :wrong_resolution}), do: gettext("resolution not preferred")
  defp verdict_reason({:rejected, :wrong_source}), do: gettext("source not preferred")
  defp verdict_reason({:rejected, :wrong_protocol}), do: gettext("no client for protocol")
  defp verdict_reason(_), do: ""
end
