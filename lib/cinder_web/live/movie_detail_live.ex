defmodule CinderWeb.MovieDetailLive do
  @moduledoc """
  Admin movie detail at `/movies/:id`: descriptive TMDB metadata (overview / runtime / genres /
  rating / release date — lazily backfilled on first view via `Catalog.enrich_movie/1`, off-process
  so it never blocks render) plus the downloaded-file panel (resolution / size / source / language /
  release title). Read-only — management (edit / cancel / delete) stays on `/library`. Subscribes to
  the `movies` topic so a status change advances the badge live.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [format_date_year: 1, humanize_bytes: 1]

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # :id is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %Movie{} = movie <- Catalog.get_movie_by_id(id) do
      if connected?(socket), do: Catalog.subscribe()
      {:ok, socket |> assign(movie: movie) |> maybe_enrich(movie)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Movie not found."))
         |> push_navigate(to: ~p"/library")}
    end
  end

  # Backfill descriptive metadata once, off the render path (vote_average-nil sentinel).
  defp maybe_enrich(socket, %Movie{vote_average: nil} = movie) do
    if connected?(socket),
      do: start_async(socket, :enrich, fn -> Catalog.enrich_movie(movie) end),
      else: socket
  end

  defp maybe_enrich(socket, %Movie{}), do: socket

  @impl true
  def handle_async(:enrich, {:ok, %Movie{}}, socket) do
    # Re-read rather than trust the task's struct: a status transition may have landed during the
    # backfill, and the task's snapshot carries the pre-transition status — assigning it would
    # revert the badge. The fresh row has both the new metadata and the current status.
    case Catalog.get_movie_by_id(socket.assigns.movie.id) do
      nil -> {:noreply, socket}
      movie -> {:noreply, assign(socket, movie: movie)}
    end
  end

  # A failed backfill leaves the un-enriched row on screen; the page still renders.
  def handle_async(:enrich, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, %Movie{id: id} = movie}, socket) do
    if id == socket.assigns.movie.id,
      do: {:noreply, assign(socket, movie: movie)},
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/library"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Library")}
      </.link>

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
              <.status_badge kind={:movie} status={@movie.status} />
            </:actions>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@movie.release_date} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@movie.release_date)}
            </span>
            <span :if={@movie.runtime} class="inline-flex items-center gap-1">
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

  # A one-decimal rating string ("8.4"); vote_average is an Ecto :float.
  defp rating(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp rating(v), do: to_string(v)

  defp has_file?(%Movie{file_path: fp}), do: is_binary(fp) and fp != ""
end
