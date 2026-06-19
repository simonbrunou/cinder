defmodule Cinder.Catalog do
  @moduledoc """
  Discovery + watchlist: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.
  """
  import Ecto.Query

  alias Cinder.Catalog.Movie
  alias Cinder.Repo

  @topic "movies"

  @doc """
  Searches TMDB for `query`. A blank/whitespace query short-circuits to `{:ok, []}`
  with no API call.
  """
  def search_movies(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search(query)
    end
  end

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

  @doc """
  Adds a movie to the watchlist as `:requested`. Returns `{:ok, movie}` or
  `{:error, changeset}` (e.g. a duplicate `tmdb_id`).
  """
  def add_to_watchlist(attrs) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists watchlisted movies, newest first."
  def list_watchlist do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Subscribes the caller to movie state-change broadcasts (`{:movie_updated, movie}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Fetches full movie details from TMDB (the details endpoint carries `imdb_id`)."
  def get_movie(tmdb_id), do: tmdb().get_movie(tmdb_id)

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id` and `:imdb_id`.
  """
  def transition(%Movie{} = movie, attrs) do
    with {:ok, updated} <- movie |> Movie.transition_changeset(attrs) |> Repo.update() do
      Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, {:movie_updated, updated})
      {:ok, updated}
    end
  end
end
