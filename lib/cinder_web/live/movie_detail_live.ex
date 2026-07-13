defmodule CinderWeb.MovieDetailLive do
  @moduledoc """
  Admin movie console at `/movies/:id`: descriptive TMDB metadata (overview / runtime / genres /
  rating / release date — refreshed on each detail view via `Catalog.enrich_movie/1`, off-process
  so it never blocks render), the downloaded-file panel, **and** management — edit / cancel / delete,
  retry a parked movie, "Find a better match", cancel an in-flight upgrade, and set the preferred
  language. Mirrors the `/series/:id` console so movies and TV behave identically. Every write goes
  through an existing `Catalog` function; subscribes to the `movies` topic so a status change (its
  own or another tab's) advances the page live.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [format_date_year: 1, humanize_bytes: 1, rating: 1]

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @parked [:no_match, :search_failed, :import_failed]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # :id is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %Movie{} = movie <- Catalog.get_movie_by_id(id) do
      if connected?(socket), do: Catalog.subscribe()

      {:ok,
       socket
       |> assign(
         movie: movie,
         editing?: false,
         confirming: nil,
         form: nil,
         alias_form: alias_form(),
         delete_files: false,
         searching?: false
       )
       |> refresh_identity(movie)
       |> maybe_enrich(movie)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Movie not found."))
         |> push_navigate(to: ~p"/library")}
    end
  end

  # Refresh descriptive metadata off the render path whenever the detail page opens.
  defp maybe_enrich(socket, %Movie{} = movie) do
    if connected?(socket),
      do: start_async(socket, :enrich, fn -> Catalog.enrich_movie(movie) end),
      else: socket
  end

  # --- edit ---
  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply,
     assign(socket,
       editing?: true,
       confirming: nil,
       form: to_form(Movie.changeset(socket.assigns.movie, %{}))
     )}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing?: false, form: nil)}

  def handle_event("save", %{"movie" => attrs}, socket) do
    case Catalog.update_movie(socket.assigns.movie, attrs) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(editing?: false, form: nil)
         |> assign_fresh(socket.assigns.movie.id)
         |> put_flash(:info, gettext("Movie updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # --- cancel / delete ---
  def handle_event("ask_cancel", _params, socket),
    do: {:noreply, assign(socket, confirming: :cancel, editing?: false)}

  def handle_event("ask_delete", _params, socket),
    do: {:noreply, assign(socket, confirming: :delete, editing?: false, delete_files: false)}

  def handle_event("toggle_delete_files", _params, socket),
    do: {:noreply, assign(socket, delete_files: !socket.assigns.delete_files)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, delete_files: false)}

  def handle_event("confirm_cancel", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.cancel_movie(socket.assigns.movie, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> assign_fresh(socket.assigns.movie.id)
         |> put_flash(:info, gettext("Movie cancelled."))}

      {:error, :not_cancellable} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("That movie can't be cancelled."))}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't cancel that movie."))}
    end
  end

  def handle_event("confirm_delete", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_movie(socket.assigns.movie, actor,
           delete_files: socket.assigns.delete_files
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Movie deleted."))
         |> push_navigate(to: ~p"/library")}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete that movie."))}
    end
  end

  # --- pipeline actions ---
  def handle_event("retry", _params, socket) do
    # A guarded miss (the movie already re-entered the pipeline) must not be silent —
    # the badge visibly doesn't reset otherwise.
    socket =
      case Catalog.retry_movie(socket.assigns.movie) do
        {:error, _} ->
          put_flash(socket, :error, gettext("Couldn't retry: that movie has already moved on."))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_upgrade", _params, socket) do
    socket =
      case Catalog.abort_upgrade(socket.assigns.movie, socket.assigns.current_scope.user) do
        {:error, _} ->
          put_flash(
            socket,
            :error,
            gettext("Couldn't cancel: that upgrade has already moved on.")
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Toggle the manual-search panel (re-clicking closes it).
  def handle_event("manual_search", _params, socket),
    do: {:noreply, assign(socket, searching?: !socket.assigns.searching?)}

  def handle_event("set_movie_language", %{"preferred_language" => lang}, socket)
      when lang in ["original", "french", "any"] do
    # On success the {:movie_updated} broadcast reloads @movie; on error the dropdown visually
    # snaps back, so say why — mirrors set_series_language on /series/:id.
    case Catalog.set_movie_language(socket.assigns.movie, lang) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update the language."))}
    end
  end

  def handle_event("set_media_profile", %{"media_profile" => profile}, socket)
      when profile in ["auto", "standard", "anime"] do
    case Catalog.set_media_profile(socket.assigns.movie, String.to_existing_atom(profile)) do
      {:ok, _} ->
        {:noreply, assign_fresh(socket, socket.assigns.movie.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update the profile."))}
    end
  end

  def handle_event("save_alias", %{"alias" => params}, socket) when is_map(params) do
    result =
      case params["id"] do
        id when id in [nil, ""] -> Catalog.save_manual_alias(socket.assigns.movie, params)
        id -> update_current_alias(socket.assigns.movie, parse_alias_id(id), params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:alias_form, alias_form())
         |> refresh_identity(socket.assigns.movie)}

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
           current_manual_alias(socket.assigns.movie, id) do
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
           current_manual_alias(socket.assigns.movie, id),
         {:ok, _} <- Catalog.delete_manual_alias(socket.assigns.movie, alias_record.id) do
      {:noreply, refresh_identity(socket, socket.assigns.movie)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:enrich, {:ok, %Movie{}}, socket),
    do: {:noreply, assign_fresh(socket, socket.assigns.movie.id)}

  # A failed refresh leaves the current row on screen; the page still renders.
  def handle_async(:enrich, {:exit, _reason}, socket), do: {:noreply, socket}

  # The manual-search panel forwards a chosen release back here (it owns no Catalog writes).
  @impl true
  def handle_info({:manual_grab, :movie, _movie, release}, socket) do
    {level, msg} = grab_flash(Catalog.manual_grab_movie(socket.assigns.movie, release))
    {:noreply, socket |> assign(searching?: false) |> put_flash(level, msg)}
  end

  def handle_info({:movie_updated, %Movie{id: id}}, socket) do
    if id == socket.assigns.movie.id,
      do: {:noreply, assign_fresh(socket, id)},
      else: {:noreply, socket}
  end

  def handle_info({:movie_deleted, id}, socket) do
    if id == socket.assigns.movie.id do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Movie deleted."))
       |> push_navigate(to: ~p"/library")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp grab_flash({:ok, _movie}), do: {:info, gettext("Grabbing the selected release…")}

  defp grab_flash({:error, :not_grabbable}),
    do: {:error, gettext("That movie can't be grabbed right now.")}

  defp grab_flash({:error, _reason}), do: {:error, gettext("Couldn't grab that release.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/library"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Library")}
      </.link>

      <div class="mb-4 flex flex-wrap items-center gap-2">
        <.button type="button" variant="neutral" size="sm" phx-click="edit">
          {gettext("Edit")}
        </.button>
        <.button
          :if={Catalog.cancellable?(@movie)}
          type="button"
          variant="warning"
          size="sm"
          phx-click="ask_cancel"
        >
          {gettext("Cancel")}
        </.button>
        <.button
          :if={not Catalog.cancellable?(@movie)}
          type="button"
          variant="danger"
          size="sm"
          phx-click="ask_delete"
        >
          {gettext("Delete")}
        </.button>
      </div>

      <.form
        :if={@editing?}
        for={@form}
        id="movie-form"
        phx-submit="save"
        class="mb-6 flex flex-wrap items-end gap-2"
      >
        <.input field={@form[:title]} type="text" label={gettext("Title")} />
        <.input field={@form[:year]} type="number" label={gettext("Year")} />
        <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
          {gettext("Save")}
        </.button>
        <.button variant="ghost" size="sm" type="button" phx-click="cancel_edit">
          {gettext("Cancel edit")}
        </.button>
      </.form>

      <.confirm_action
        :if={@confirming == :cancel}
        id="confirm-cancel-movie"
        class="mb-6"
        on_confirm="confirm_cancel"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Cancel movie")}
        variant="warning"
      >
        <:caveat>{gettext("Cancel this movie and remove its download?")}</:caveat>
      </.confirm_action>

      <.confirm_action
        :if={@confirming == :delete}
        id="confirm-delete-movie"
        class="mb-6"
        on_confirm="confirm_delete"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Delete")}
        checkbox_event="toggle_delete_files"
        checkbox_checked={@delete_files}
        checkbox_label={gettext("Also delete the file from disk")}
      >
        <:caveat>{gettext("Delete this movie's record?")}</:caveat>
      </.confirm_action>

      <div class="flex flex-col gap-6 sm:flex-row">
        <img
          :if={@movie.poster_path}
          src={poster_url(@movie.poster_path)}
          alt={@movie.title}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div
          :if={!@movie.poster_path}
          class="grid aspect-[2/3] w-40 shrink-0 place-items-center rounded bg-base-300 text-sm text-base-content/70"
        >
          {gettext("No poster")}
        </div>

        <div class="min-w-0 flex-1">
          <.header>
            {@movie.title}
            <span :if={@movie.year} class="font-normal text-base-content/70">({@movie.year})</span>
            <:actions>
              <.status_badge
                kind={:movie}
                status={@movie.status}
                progress={@movie.download_progress}
                speed={@movie.download_speed}
                eta={@movie.download_eta}
              />
            </:actions>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@movie.release_date} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@movie.release_date)}
            </span>
            <span
              :if={is_integer(@movie.runtime) and @movie.runtime > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-clock" class="size-4" />{gettext("%{n} min", n: @movie.runtime)}
            </span>
            <span
              :if={is_number(@movie.vote_average) and @movie.vote_average > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-star" class="size-4" />{rating(@movie.vote_average)}
            </span>
          </div>

          <div :if={@movie.genres not in [nil, []]} class="mt-3 flex flex-wrap gap-1">
            <span :for={g <- @movie.genres} class="badge badge-outline badge-sm">{g}</span>
          </div>

          <p :if={@movie.overview} class="mt-4 max-w-prose text-sm leading-relaxed">
            {@movie.overview}
          </p>
          <p :if={is_nil(@movie.overview)} class="mt-4 text-sm text-base-content/50">
            {gettext("No description available.")}
          </p>
        </div>
      </div>

      <div class="mt-4 grid max-w-2xl gap-3 sm:grid-cols-2">
        <form id="movie-language-form" phx-change="set_movie_language">
          <.language_select value={@movie.preferred_language} />
        </form>
        <div>
          <.form for={@profile_form} id="movie-profile-form" phx-change="set_media_profile">
            <.profile_select field={@profile_form[:media_profile]} />
          </.form>
          <.profile_summary id="movie-profile-summary" summary={@profile_summary} />
        </div>
      </div>

      <section class="mt-6 max-w-3xl" aria-labelledby="movie-aliases-heading">
        <h2 id="movie-aliases-heading" class="mb-2 text-lg font-semibold">
          {gettext("Title aliases")}
        </h2>
        <p
          id="movie-alias-edit-status"
          role="status"
          aria-live="polite"
          class="mb-2 text-sm text-base-content/60"
        >
          <%= if @alias_form[:id].value not in [nil, ""] do %>
            {gettext("Editing alias %{title}", title: @alias_form[:title].value)}
          <% end %>
        </p>
        <.form
          for={@alias_form}
          id="movie-alias-form"
          phx-submit="save_alias"
          class="grid items-end gap-x-2 sm:grid-cols-2 lg:grid-cols-5"
        >
          <.input field={@alias_form[:id]} type="hidden" />
          <.input
            field={@alias_form[:title]}
            id="movie-alias-title"
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

        <div id="movie-title-aliases" phx-update="stream" class="divide-y divide-base-200">
          <p
            :if={@aliases_empty?}
            id="movie-aliases-empty"
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
                id={"edit-movie-alias-#{title_alias.id}"}
                type="button"
                variant="ghost"
                size="sm"
                phx-click={JS.push("edit_alias") |> JS.focus(to: "#movie-alias-title")}
                phx-value-id={title_alias.id}
                aria-label={gettext("Edit alias %{title}", title: title_alias.title)}
              >
                {gettext("Edit")}
              </.button>
              <.button
                id={"delete-movie-alias-#{title_alias.id}"}
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
      </section>

      <div
        :if={parked?(@movie.status) or @movie.status in [:available, :upgrading]}
        class="mt-4 flex flex-wrap items-center gap-2"
      >
        <.button
          :if={parked?(@movie.status)}
          type="button"
          variant="ghost"
          size="sm"
          phx-click="retry"
          phx-disable-with={gettext("Retrying…")}
        >
          {gettext("Retry")}
        </.button>
        <.button
          :if={@movie.status == :available or parked?(@movie.status)}
          type="button"
          variant="ghost"
          size="sm"
          phx-click="manual_search"
        >
          {gettext("Find a better match")}
        </.button>
        <.button
          :if={@movie.status == :upgrading}
          type="button"
          variant="ghost"
          size="sm"
          phx-click="cancel_upgrade"
        >
          {gettext("Cancel upgrade")}
        </.button>
      </div>

      <.live_component
        :if={@searching?}
        module={CinderWeb.ManualSearchComponent}
        id={"ms-movie-#{@movie.id}"}
        mode={:movie}
        target={@movie}
      />

      <section :if={has_file?(@movie)} class="mt-8">
        <h2 class="mb-2 text-lg font-semibold">{gettext("Downloaded file")}</h2>
        <div class="rounded-box bg-base-200/50 p-4">
          <dl class="grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-4">
            <div :if={@movie.imported_resolution}>
              <dt class="text-base-content/60">{gettext("Resolution")}</dt>
              <dd class="font-medium">{@movie.imported_resolution}</dd>
            </div>
            <div :if={humanize_bytes(@movie.imported_size)}>
              <dt class="text-base-content/60">{gettext("Size")}</dt>
              <dd class="font-medium">{humanize_bytes(@movie.imported_size)}</dd>
            </div>
            <div :if={@movie.imported_source}>
              <dt class="text-base-content/60">{gettext("Source")}</dt>
              <dd class="font-medium">{@movie.imported_source}</dd>
            </div>
            <div :if={@movie.imported_language}>
              <dt class="text-base-content/60">{gettext("Language")}</dt>
              <dd class="font-medium">{@movie.imported_language}</dd>
            </div>
            <div :if={@movie.imported_audio_languages not in [nil, []]}>
              <dt class="text-base-content/60">{gettext("Audio")}</dt>
              <dd class="flex flex-wrap gap-1 font-medium">
                <span :for={l <- @movie.imported_audio_languages} class="badge badge-ghost badge-xs">{l}</span>
              </dd>
            </div>
            <div :if={
              @movie.imported_embedded_subtitles not in [nil, []] or
                @movie.imported_sidecar_subtitles not in [nil, []]
            }>
              <dt class="text-base-content/60">{gettext("Subtitles")}</dt>
              <dd class="flex flex-wrap gap-1 font-medium">
                <span
                  :for={l <- @movie.imported_embedded_subtitles || []}
                  class="badge badge-ghost badge-xs"
                >
                  {l} <span class="opacity-60">{gettext("embedded")}</span>
                </span>
                <span
                  :for={l <- @movie.imported_sidecar_subtitles || []}
                  class="badge badge-outline badge-xs"
                >
                  {l} <span class="opacity-60">{gettext("sidecar")}</span>
                </span>
              </dd>
            </div>
          </dl>
          <div :if={@movie.release_title} class="mt-3 border-t border-base-300 pt-3">
            <dt class="text-sm text-base-content/60">{gettext("Release")}</dt>
            <dd class="break-all font-mono text-xs">{@movie.release_title}</dd>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Re-read the row fresh from the DB — used after the async refresh, a `:movie_updated`
  # broadcast, and every write. A status transition through the unguarded `transition/2` echoes the
  # caller's in-memory struct, which may predate this row's metadata refresh (enrich doesn't
  # broadcast); re-reading pulls both the current status and the persisted metadata. A row deleted
  # mid-flight leaves the current assign in place (the `:movie_deleted` handler drives the redirect).
  defp assign_fresh(socket, id) do
    case Catalog.get_movie_by_id(id) do
      nil -> socket
      movie -> socket |> assign(movie: movie) |> refresh_identity(movie)
    end
  end

  defp refresh_identity(socket, movie) do
    aliases = Catalog.list_title_aliases(movie)

    socket
    |> assign(
      profile_form: profile_form(movie),
      profile_summary: Catalog.media_profile_summary(movie),
      aliases_empty?: aliases == []
    )
    |> stream(:title_aliases, aliases, reset: true)
  end

  defp profile_form(movie),
    do: to_form(%{"media_profile" => Atom.to_string(movie.media_profile)})

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

  defp update_current_alias(movie, id, params) do
    case current_manual_alias(movie, id) do
      nil -> {:error, :not_manual_alias}
      alias_record -> Catalog.update_manual_alias(movie, alias_record.id, params)
    end
  end

  defp current_manual_alias(movie, id) do
    Enum.find(Catalog.list_title_aliases(movie), &(&1.id == id and &1.precedence == :manual))
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

  defp parked?(status), do: status in @parked

  defp has_file?(%Movie{file_path: fp}), do: is_binary(fp) and fp != ""
end
