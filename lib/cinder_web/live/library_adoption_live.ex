defmodule CinderWeb.LibraryAdoptionLive do
  @moduledoc """
  Admin workflow for scanning configured library roots and adopting confirmed
  movie and series matches without blocking the LiveView process.
  """

  use CinderWeb, :live_view

  alias Cinder.Catalog.Episode
  alias Cinder.Library.Adoption

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       candidates: [],
       counts: %{auto_matched: 0, ambiguous: 0, unmatched: 0},
       form: to_form(%{}, as: :adoption),
       scanned?: false,
       scanning?: false,
       adopting?: false
     )
     |> stream_configure(:auto_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(:ambiguous_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(:unmatched_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream(:auto_candidates, [])
     |> stream(:ambiguous_candidates, [])
     |> stream(:unmatched_candidates, [])}
  end

  @impl true
  def handle_event("scan", _params, %{assigns: %{scanning?: false, adopting?: false}} = socket),
    do: {:noreply, start_scan(socket)}

  def handle_event("adopt", %{"adoption" => params}, %{assigns: %{adopting?: false}} = socket)
      when is_map(params) do
    confirmed = confirmed_candidates(socket.assigns.candidates, params)

    case confirmed do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one match to adopt."))}

      candidates ->
        {:noreply,
         socket
         |> assign(adopting?: true)
         |> start_async(:adopt, fn -> Adoption.adopt(candidates) end)}
    end
  end

  # Client-controlled events and malformed params are ignored rather than crashing the page.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:scan, {:ok, candidates}, socket) when is_list(candidates),
    do: {:noreply, put_candidates(socket, candidates)}

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false)
     |> put_flash(:error, gettext("Library scan failed. Please try again."))}
  end

  def handle_async(:adopt, {:ok, summary}, socket) do
    message =
      gettext("Adopted %{adopted}; skipped %{skipped}.",
        adopted: summary.adopted,
        skipped: summary.skipped
      )

    {:noreply,
     socket
     |> assign(adopting?: false)
     |> put_flash(:info, message)
     |> start_scan()}
  end

  def handle_async(:adopt, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(adopting?: false)
     |> put_flash(:error, gettext("Adoption failed. Please try again."))}
  end

  defp start_scan(socket) do
    socket
    |> assign(scanning?: true)
    |> start_async(:scan, &Adoption.scan/0)
  end

  defp put_candidates(socket, candidates) do
    auto = Enum.filter(candidates, &(&1.status == :auto_matched))
    ambiguous = Enum.filter(candidates, &(&1.status == :ambiguous))
    unmatched = Enum.filter(candidates, &(&1.status == :unmatched))

    socket
    |> assign(
      candidates: candidates,
      counts: %{
        auto_matched: length(auto),
        ambiguous: length(ambiguous),
        unmatched: length(unmatched)
      },
      form: to_form(%{}, as: :adoption),
      scanned?: true,
      scanning?: false
    )
    |> stream(:auto_candidates, auto, reset: true)
    |> stream(:ambiguous_candidates, ambiguous, reset: true)
    |> stream(:unmatched_candidates, unmatched, reset: true)
  end

  defp confirmed_candidates(candidates, params) do
    selected = params |> Map.get("selected", []) |> List.wrap() |> parse_ids()
    chosen = Map.get(params, "chosen", %{})
    parts = Map.get(params, "parts", %{})

    Enum.flat_map(candidates, &confirm_candidate(&1, selected, chosen, parts))
  end

  defp confirm_candidate(
         %{status: :auto_matched, id: id} = candidate,
         selected,
         _chosen,
         parts
       ) do
    if MapSet.member?(selected, id) do
      [put_part_choices(candidate, candidate_choices(parts, id))]
    else
      []
    end
  end

  defp confirm_candidate(%{status: :ambiguous, id: id} = candidate, _selected, chosen, _parts)
       when is_map(chosen) do
    case parse_id(Map.get(chosen, to_string(id))) do
      nil -> []
      tmdb_id -> [Map.put(candidate, :chosen_tmdb_id, tmdb_id)]
    end
  end

  defp confirm_candidate(_candidate, _selected, _chosen, _parts), do: []

  defp candidate_choices(parts, candidate_id) when is_map(parts) do
    case Map.get(parts, to_string(candidate_id), %{}) do
      choices when is_map(choices) -> choices
      _ -> %{}
    end
  end

  defp candidate_choices(_parts, _candidate_id), do: %{}

  defp put_part_choices(candidate, choices) do
    files =
      Enum.map(Map.get(candidate, :files, []), fn file ->
        target = parse_id(Map.get(choices, to_string(Map.get(file, :id))))

        case Enum.find(Map.get(file, :part_candidates, []), &(&1.episode_number == target)) do
          nil ->
            file

          part_of ->
            %{file | status: :part, part_of: Map.take(part_of, [:season_number, :episode_number])}
        end
      end)

    Map.put(candidate, :files, files)
  end

  defp parse_ids(values) do
    values
    |> Enum.map(&parse_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp title(candidate) do
    if candidate.year,
      do: "#{candidate.title} (#{candidate.year})",
      else: candidate.title
  end

  defp match_title(match) do
    if match.year, do: "#{match.title} (#{match.year})", else: match.title
  end

  defp kind_label(:movie), do: gettext("Movie")
  defp kind_label(:series), do: gettext("Series")

  defp file_label(%{season_number: season, episode_numbers: episodes})
       when is_integer(season) and episodes != [],
       do: Episode.codes_label(season, episodes)

  defp file_label(_file), do: gettext("No episode number")

  defp part_label(part) do
    code = Episode.code(part.season_number, part.episode_number)
    if part.title in [nil, ""], do: code, else: "#{code} · #{part.title}"
  end

  defp reason_text({:episode_not_found, _missing}),
    do: gettext("The parsed episode does not exist in TMDB.")

  defp reason_text({:duplicate_episode_claim, _keys}),
    do: gettext("Several files claim this episode; resolve the duplicates on disk first.")

  defp reason_text(:episode_number_not_found),
    do: gettext("No SxxEyy episode number was found.")

  defp reason_text(:no_matched_episodes),
    do: gettext("None of the parsed episodes exist in TMDB.")

  defp reason_text({:scan_failed, _reason}),
    do: gettext("This library root could not be scanned.")

  defp reason_text({:tmdb_search_failed, _reason}),
    do: gettext("TMDB search failed.")

  defp reason_text({:tmdb_details_failed, _reason}),
    do: gettext("TMDB episode details could not be loaded.")

  defp reason_text(_reason), do: gettext("No safe match was found.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Adopt existing library")}
        <:subtitle>
          {gettext(
            "Scan your movie and TV roots, confirm matches, and bring existing files under Cinder's management."
          )}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/library"} class="btn btn-ghost">{gettext("Back to library")}</.link>
        </:actions>
      </.header>

      <div class="mb-6 flex flex-wrap items-center gap-3">
        <.button
          id="scan-library"
          type="button"
          phx-click="scan"
          disabled={@scanning? or @adopting?}
        >
          {if @scanning?, do: gettext("Scanning…"), else: gettext("Scan")}
        </.button>
        <.spinner :if={@scanning?} label={gettext("Scanning library roots…")} />
        <p class="text-sm text-base-content/70">
          {gettext(
            "Scanning only reads your library. Nothing is changed until you adopt a confirmed match."
          )}
        </p>
      </div>

      <.empty_state
        :if={not @scanned? and not @scanning?}
        icon="hero-folder-magnifying-glass"
        title={gettext("Ready to scan")}
        message={gettext("Cinder will compare video files with the paths it already manages.")}
      />

      <div :if={@scanned? and Enum.sum(Map.values(@counts)) == 0} id="no-unmanaged-files">
        <.empty_state
          icon="hero-check-circle"
          title={gettext("No unmanaged files found")}
          message={gettext("Every discovered video file is already managed by Cinder.")}
        />
      </div>

      <.form
        :if={Enum.sum(Map.values(@counts)) > 0}
        for={@form}
        id="adoption-form"
        phx-submit="adopt"
        class="space-y-8"
      >
        <section :if={@counts.auto_matched > 0} aria-labelledby="auto-matches-heading">
          <h2 id="auto-matches-heading" class="mb-3 text-xl font-semibold">
            {gettext("Auto-matched")} ({@counts.auto_matched})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("Exact title and year matches are selected by default.")}
          </p>
          <div id="auto-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.auto_candidates}
              id={dom_id}
              class="card border border-base-300 bg-base-100"
            >
              <div class="card-body gap-3 p-4">
                <label class="flex min-h-11 cursor-pointer items-start gap-3">
                  <input
                    type="checkbox"
                    name="adoption[selected][]"
                    value={candidate.id}
                    checked
                    class="checkbox checkbox-primary mt-0.5"
                    aria-label={gettext("Adopt %{title}", title: title(candidate))}
                  />
                  <span class="min-w-0">
                    <span class="block font-semibold">{title(candidate)}</span>
                    <span class="text-sm text-base-content/70">
                      {kind_label(candidate.kind)} · {gettext("Matched to %{title}",
                        title: match_title(candidate.match)
                      )}
                    </span>
                  </span>
                </label>

                <ul :if={candidate.kind == :series} class="space-y-1 text-sm">
                  <li :for={file <- candidate.files} class="space-y-1">
                    <div class="flex flex-wrap gap-x-2">
                      <span class="font-mono">{Path.basename(file.path)}</span>
                      <span class="text-base-content/60">{file_label(file)}</span>
                      <span :if={file.status == :matched} class="text-success">
                        {gettext("Matched")}
                      </span>
                      <span :if={file.status == :unmatched} class="text-warning">
                        {gettext("Held: %{reason}", reason: reason_text(file.reason))}
                      </span>
                    </div>
                    <label
                      :if={Map.get(file, :part_candidates, []) != []}
                      class="flex flex-wrap items-center gap-2 text-sm"
                    >
                      <span>{gettext("Needs confirmation")}</span>
                      <select
                        id={"part-assignment-#{candidate.id}-#{file.id}"}
                        name={"adoption[parts][#{candidate.id}][#{file.id}]"}
                        class="select select-sm select-bordered"
                      >
                        <option value="">{gettext("Held")}</option>
                        <option
                          :for={part <- file.part_candidates}
                          value={part.episode_number}
                        >
                          {part_label(part)}
                        </option>
                      </select>
                    </label>
                  </li>
                </ul>
              </div>
            </article>
          </div>
        </section>

        <section :if={@counts.ambiguous > 0} aria-labelledby="ambiguous-heading">
          <h2 id="ambiguous-heading" class="mb-3 text-xl font-semibold">
            {gettext("Needs confirmation")} ({@counts.ambiguous})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("Choose one TMDB result, or leave the item unselected to skip it.")}
          </p>
          <div id="ambiguous-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.ambiguous_candidates}
              id={dom_id}
              class="card border border-warning/40 bg-base-100"
            >
              <div class="card-body gap-3 p-4">
                <div>
                  <p class="font-semibold">{title(candidate)}</p>
                  <p class="text-sm text-base-content/70">{kind_label(candidate.kind)}</p>
                </div>
                <fieldset class="space-y-2">
                  <legend class="sr-only">
                    {gettext("TMDB match for %{title}", title: title(candidate))}
                  </legend>
                  <label
                    :for={match <- candidate.candidates}
                    class="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"adoption[chosen][#{candidate.id}]"}
                      value={match.tmdb_id}
                      class="radio radio-primary"
                    />
                    <span>
                      <span class="block">{match_title(match)}</span>
                      <span class="text-xs text-base-content/60">
                        {gettext("TMDB %{id}", id: match.tmdb_id)}
                      </span>
                    </span>
                  </label>
                  <p :if={candidate.candidates == []} class="text-sm text-warning">
                    {gettext("TMDB returned no candidates. This item will be skipped.")}
                  </p>
                </fieldset>
              </div>
            </article>
          </div>
        </section>

        <section :if={@counts.unmatched > 0} aria-labelledby="unmatched-heading">
          <h2 id="unmatched-heading" class="mb-3 text-xl font-semibold">
            {gettext("Held")} ({@counts.unmatched})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("These files cannot be adopted safely and will not be changed.")}
          </p>
          <div id="unmatched-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.unmatched_candidates}
              id={dom_id}
              class="card border border-error/30 bg-base-100"
            >
              <div class="card-body gap-2 p-4">
                <p class="font-semibold">{title(candidate)}</p>
                <p class="text-sm text-error">{reason_text(candidate.reason)}</p>
                <ul :if={candidate.kind == :series} class="space-y-1 text-sm">
                  <li :for={file <- candidate.files}>
                    <span class="font-mono">{Path.basename(file.path)}</span>
                    <span class="text-base-content/60"> · {reason_text(file.reason)}</span>
                  </li>
                </ul>
              </div>
            </article>
          </div>
        </section>

        <div :if={@counts.auto_matched + @counts.ambiguous > 0} class="flex items-center gap-3">
          <.button id="adopt-selected" type="submit" disabled={@adopting? or @scanning?}>
            {if @adopting?, do: gettext("Adopting…"), else: gettext("Adopt selected")}
          </.button>
          <.spinner :if={@adopting?} label={gettext("Adopting selected files…")} />
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
