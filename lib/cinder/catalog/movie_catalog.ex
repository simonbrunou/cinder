defmodule Cinder.Catalog.MovieCatalog do
  @moduledoc """
  Movie rows: creating one at `:requested` and reading them. A movie's status changes only
  through `Cinder.Catalog.MovieLifecycle`; its preferences through `Cinder.Catalog.MediaProfiles`.

  Creation never broadcasts: it may run inside a caller's transaction, so announcing it
  (`Cinder.Catalog.Events.movie_created/1`) is the caller's post-commit job.
  """
  import Ecto.Query

  alias Cinder.Catalog.{Discovery, Identity, Movie}
  alias Cinder.Repo

  @doc """
  Persists a movie as `:requested`. Returns `{:ok, movie}` or
  `{:error, changeset}` (e.g. a duplicate `tmdb_id`).
  """
  def add_movie(attrs) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists movies, newest first."
  def list_movies do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Maps every movie's `tmdb_id` to its pipeline `status`."
  def movie_status_map, do: Map.new(list_movies(), &{&1.tmdb_id, &1.status})

  @doc "Counts movies grouped by pipeline `status` (`%{status => count}`)."
  def movie_status_counts do
    Repo.all(from m in Movie, group_by: m.status, select: {m.status, count(m.id)}) |> Map.new()
  end

  @doc "The `limit` most-recently-updated movies, newest first (dashboard recent-activity slice)."
  def recent_movies(limit) do
    Repo.all(from m in Movie, order_by: [desc: m.updated_at], limit: ^limit)
  end

  @doc "Fetches a movie by primary key, or `nil`."
  def get_movie_by_id(id), do: Repo.get(Movie, id)

  @doc "Fetches a movie by TMDB id, or `nil`."
  def get_movie_by_tmdb_id(tmdb_id), do: Repo.get_by(Movie, tmdb_id: tmdb_id)

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc "Available movies that have an imported file (subtitle-fetch candidates)."
  def list_available_movies_with_file do
    Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
  end

  @doc """
  Returns `{:ok, movie, :existing}` for the existing row (at its current status) if one
  already exists for `attrs.tmdb_id`, or `{:ok, movie, :created}` after inserting a new
  movie at `:requested`.

  No broadcast here — this may run inside a caller's transaction (a savepoint when joined
  to one already open), so announcing creation is the caller's post-commit job
  (`Cinder.Requests.Approval.Movie.publish/2` broadcasts `{:movie_created, movie}` once
  the approval transaction has committed, using the returned `:created` marker).

  Confirm/fill (the requester's media-profile confirmation and language pick) is NOT applied
  here — `Cinder.Requests.Approval.Movie` calls `Cinder.Catalog.apply_confirmed_media/4` itself,
  after the approval transaction commits, so a fill/confirm failure can't roll back the atomic
  movie-creation + request-approval write. A fresh insert already carries both fields straight
  from `attrs` (`Movie.changeset/2` casts them), so nothing is lost for the create case.

  A lost insert race (unique_constraint on `:tmdb_id`) is handled by re-fetching the
  winner and returning it as `:existing`, so callers always get `{:ok, movie, marker}`.
  """
  def find_or_create_at_requested(attrs, aliases \\ []) do
    case get_movie_by_tmdb_id(attrs.tmdb_id) do
      %Movie{} = movie -> {:ok, movie, :existing}
      nil -> do_insert_at_requested(attrs, aliases)
    end
  end

  @doc "Fetches requested-movie details and aliases before any Catalog write."
  def prepare_requested_movie(attrs) do
    tmdb_id = Map.fetch!(attrs, :tmdb_id)

    case get_movie_by_tmdb_id(tmdb_id) do
      %Movie{} ->
        {:ok, %{attrs: attrs, aliases: []}}

      nil ->
        with {:ok, info} <- Discovery.get_movie(tmdb_id),
             {:ok, aliases} <- tmdb().get_movie_alternative_titles(info.tmdb_id) do
          create_attrs =
            info
            |> Map.take(Movie.creation_fields())
            |> Map.merge(Map.take(attrs, [:preferred_language, :media_profile, :profile_id]))

          {:ok, %{attrs: create_attrs, aliases: aliases}}
        end
    end
  end

  defp do_insert_at_requested(attrs, aliases) do
    result =
      Repo.transaction(fn ->
        with {:ok, movie} <- %Movie{} |> Movie.changeset(attrs) |> Repo.insert(),
             {:ok, _aliases} <-
               Identity.replace_provider_aliases(
                 movie,
                 "tmdb",
                 "alternative_titles",
                 :inferred,
                 aliases
               ) do
          movie
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, movie} ->
        {:ok, movie, :created}

      {:error, reason} ->
        # Lost the insert race (unique_constraint :tmdb_id) — the row now exists.
        case get_movie_by_tmdb_id(attrs.tmdb_id) do
          %Movie{} = movie -> {:ok, movie, :existing}
          nil -> {:error, reason}
        end
    end
  end

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
