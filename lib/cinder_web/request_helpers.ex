defmodule CinderWeb.RequestHelpers do
  @moduledoc """
  Shared LiveView-effectful machinery for requesting a movie and tracking its live
  request/pipeline status, used by `DiscoverLive` and `EntityDiscoveryLive`. Unlike
  `CinderWeb.LiveHelpers` (pure functions only), this touches the socket/process —
  `start_async`, `put_flash`, and the assigns that feed `DiscoverComponents.media_grid/1`'s
  per-card badge. Each consuming LiveView keeps its own thin `handle_event("add", ...)` /
  `handle_async/3` / `handle_info/2` clauses (callbacks can't live in a helper module) and
  delegates into these.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog
  alias Cinder.Requests

  @doc "Starts the off-process `Requests.create_request/2` call behind a movie's Add form."
  def add(socket, movie, preferred, profile) do
    user = socket.assigns.current_scope.user

    attrs = %{
      target_type: "movie",
      target_id: movie.tmdb_id,
      title: movie.title,
      year: movie.year,
      poster_path: movie.poster_path,
      original_language: movie.original_language,
      preferred_language: preferred,
      proposed_media_profile: profile
    }

    start_async(socket, {:add, movie.tmdb_id, movie.title}, fn ->
      Requests.create_request(user, attrs)
    end)
  end

  @doc "Flash + request-state refresh for the `{:add, tmdb_id, title}` async result."
  def request_result(socket, title, result) do
    case result do
      {:ok, %{status: :approved}} ->
        socket
        |> put_flash(:info, gettext("%{title} added.", title: title))
        |> assign_request_state()

      {:ok, %{status: :pending}} ->
        socket
        |> put_flash(
          :info,
          gettext("%{title} requested. Awaiting approval.", title: title)
        )
        |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(
          socket,
          :error,
          gettext("You've reached your request limit. Wait for approvals to clear.")
        )

      {:error, %Ecto.Changeset{} = cs} ->
        # Only a duplicate-pending unique-constraint is the benign "already requested" case;
        # any other changeset failure is a real error, not a reassuring info toast.
        if duplicate_request?(cs) do
          put_flash(socket, :info, gettext("%{title} is already requested.", title: title))
        else
          put_flash(
            socket,
            :error,
            gettext("Couldn't request %{title}. Try again.", title: title)
          )
        end

      {:error, _} ->
        put_flash(
          socket,
          :error,
          gettext("Couldn't request %{title}. Try again.", title: title)
        )
    end
  end

  @doc """
  The user's request status per target (latest wins) plus the global movie pipeline
  status per tmdb_id; together they drive the per-title movie badge.
  """
  def assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    requests = Requests.list_for_user(user)
    request_status = latest_status_by(requests, & &1.target_id)

    # TV cards mirror the movie badge, but a series' state is per-season: key the newest season
    # request by the series tmdb_id (a season request's target_id), and treat a series as
    # available once any of its seasons has imported.
    season_requests = Enum.filter(requests, &(&1.target_type == "season"))
    series_request_status = latest_status_by(season_requests, & &1.target_id)

    socket
    |> assign(request_status: request_status, series_request_status: series_request_status)
    |> assign_available_series()
    |> assign_movie_status()
  end

  @doc """
  Series-level availability for the TV badge: the tmdb_ids with ≥1 imported season. Cheap to
  recompute on its own so a `series`-topic event needn't rebuild the whole request state.
  """
  def assign_available_series(socket) do
    assign(socket,
      available_series: MapSet.new(Catalog.available_season_keys(), fn {tid, _n} -> tid end)
    )
  end

  @doc """
  Reads the full movie-status map fresh from the DB (authoritative) on the infrequent
  paths that call this — mount, add, request events — so a just-approved/created movie
  is reflected even though its `:movie_created` broadcast rides the movies topic with no
  cross-topic ordering guarantee vs the `:request_*` event.
  """
  def assign_movie_status(socket) do
    assign(socket, movie_status: Catalog.movie_status_map())
  end

  @doc "Patches a single movie's status into the already-loaded map from a live broadcast."
  def patch_movie_status(socket, movie) do
    assign(socket,
      movie_status: Map.put(socket.assigns.movie_status, movie.tmdb_id, movie.status)
    )
  end
end
