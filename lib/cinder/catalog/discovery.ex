defmodule Cinder.Catalog.Discovery do
  @moduledoc """
  TMDB-facing discovery: search (movies/TV/people/collections), trending/rails, and
  locale-aware field lookups. Reached only through the `Cinder.Catalog.TMDB` behaviour
  (resolved from config), so tests use a Mox mock and never hit the network. Pure
  read-side of `Cinder.Catalog` — carved out of the facade as plain code motion; every
  function here is re-exported unchanged via `defdelegate` in `Cinder.Catalog`.
  """
  require Logger

  alias Cinder.Locales

  @discover_task_timeout 30_000

  @doc """
  Searches TMDB for `query`. A blank/whitespace query short-circuits to `{:ok, []}`
  with no API call.
  """
  def search_movies(query, locale \\ Locales.canonical()) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search(query, locale)
    end
  end

  @doc "TV-search variant of `search_movies/2`: blank query short-circuits to `{:ok, []}`."
  def search_tv(query, locale \\ Locales.canonical()) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search_tv(query, locale)
    end
  end

  @doc """
  Combined Discover search: movies + TV + people + collections for one query.
  Returns `{:ok, results}` where each result is a normalized search map plus a
  `:type` key (`:movie | :tv | :person | :collection`), round-robin interleaved
  across all four kinds so no one dominates the top of the grid. A
  blank/whitespace query short-circuits to `{:ok, []}` with no API call.

  The four searches run concurrently (`Task.async` + `Task.yield_many`, 30s
  timeout — above the HTTP client's ~25s worst case of connect+pool+receive); a
  side that times out, raises, or exits degrades to `{:error, reason}` like any
  other failed side rather than crashing the caller: the task fun converts its
  own raises/exits to error tuples (the tasks are linked, so an uncaught one
  would kill the LiveView), and `Task.await_many` is avoided because it would
  exit this process on a timeout instead of degrading.

  If *both* movies and TV error, returns `{:error, :search_failed}` regardless of
  the person/collection sides (the naive "all four must fail" rule would show a
  misleading "No matches" when both primary sides are down); any other partial
  failure is logged and its side is omitted — partial results beat none for
  discovery.
  """
  def search_discover(query, locale \\ Locales.canonical()) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      query
      |> discover_tasks(locale)
      |> await_discover_tasks()
      |> merge_discover()
    end
  end

  defp discover_tasks(query, locale) do
    [
      movies: discover_task(fn -> search_movies(query, locale) end),
      tv: discover_task(fn -> search_tv(query, locale) end),
      persons: discover_task(fn -> search_person(query, locale) end),
      collections: discover_task(fn -> search_collection(query, locale) end)
    ]
  end

  # Task.async links the task to the caller (the LiveView): an uncaught raise or exit
  # inside a side — a pool-checkout timeout under contention *exits* rather than
  # returning an error tuple — would kill the page before yield_many could report it.
  # Convert both into the side's normal {:error, _} contract instead.
  defp discover_task(fun) do
    Task.async(fn ->
      try do
        fun.()
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    end)
  end

  defp await_discover_tasks(tasks) do
    keys = Keyword.keys(tasks)
    yielded = tasks |> Keyword.values() |> Task.yield_many(@discover_task_timeout)

    results =
      Enum.map(yielded, fn {task, result} ->
        case result || Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> value
          {:exit, reason} -> {:error, reason}
          nil -> {:error, :timeout}
        end
      end)

    keys |> Enum.zip(results) |> Map.new()
  end

  defp merge_discover(%{movies: {:error, _} = movies, tv: {:error, _} = tv}) do
    Logger.warning("Discover search failed entirely: movies=#{inspect(movies)} tv=#{inspect(tv)}")
    {:error, :search_failed}
  end

  defp merge_discover(%{movies: movies, tv: tv, persons: persons, collections: collections}) do
    {:ok,
     interleave([
       tag(movies, :movie),
       tag(tv, :tv),
       tag(persons, :person),
       tag(collections, :collection)
     ])}
  end

  defp tag({:ok, list}, type), do: Enum.map(list, &Map.put(&1, :type, type))

  defp tag({:error, reason}, type) do
    Logger.warning("Discover #{type} search failed: #{inspect(reason)}")
    []
  end

  # Round-robin across all of `lists` so a 2-col mobile grid shows every kind near the
  # top, then any tail. Generalizes the old 2-list interleave to N lists.
  defp interleave(lists) do
    max_len = lists |> Enum.map(&length/1) |> Enum.max()

    0..max_len
    |> Enum.flat_map(fn i -> Enum.map(lists, &Enum.at(&1, i)) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  This week's trending movies + TV from TMDB, normalized like `search_discover/2`
  results (each map carries `type: :movie | :tv`).
  """
  def trending(locale \\ Locales.canonical()), do: tmdb().trending(locale)

  @doc """
  Popular movies from TMDB (`/movie/popular`), normalized like `search_movies/2`
  results (each carries `type: :movie`).
  """
  def popular_movies(locale \\ Locales.canonical()), do: tmdb().popular_movies(locale)

  @doc "Top-rated movies from TMDB (`/movie/top_rated`), same shape as `popular_movies/1`."
  def top_rated_movies(locale \\ Locales.canonical()), do: tmdb().top_rated_movies(locale)

  @doc """
  Movies currently in theaters from TMDB (`/movie/now_playing`), same shape as
  `popular_movies/1`.
  """
  def now_playing_movies(locale \\ Locales.canonical()), do: tmdb().now_playing_movies(locale)

  @doc """
  Popular TV series from TMDB (`/tv/popular`), normalized like `search_tv/2`
  results (each carries `type: :tv`).
  """
  def popular_tv(locale \\ Locales.canonical()), do: tmdb().popular_tv(locale)

  @doc "Top-rated TV series from TMDB (`/tv/top_rated`), same shape as `popular_tv/1`."
  def top_rated_tv(locale \\ Locales.canonical()), do: tmdb().top_rated_tv(locale)

  @doc """
  Movies matching TMDB genre id `genre_id` (`/discover/movie?with_genres=`), same
  shape as `popular_movies/1`.
  """
  def movies_by_genre(genre_id, locale \\ Locales.canonical()),
    do: tmdb().discover_movies(genre_id, locale)

  @doc """
  TV series matching TMDB TV genre id `genre_id` (`/discover/tv?with_genres=`),
  same shape as `popular_tv/1`.
  """
  def tv_by_genre(genre_id, locale \\ Locales.canonical()),
    do: tmdb().discover_tv(genre_id, locale)

  def search_person(query, locale \\ Locales.canonical()), do: tmdb().search_person(query, locale)

  def search_collection(query, locale \\ Locales.canonical()),
    do: tmdb().search_collection(query, locale)

  def get_person(tmdb_id, locale \\ Locales.canonical()), do: tmdb().get_person(tmdb_id, locale)

  def get_collection(tmdb_id, locale \\ Locales.canonical()),
    do: tmdb().get_collection(tmdb_id, locale)

  @doc "Fetches series details (including seasons list) from TMDB by tmdb_id."
  def tmdb_series(tmdb_id), do: tmdb().get_series(tmdb_id)

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

  @doc "Returns the localized title for `media`, falling back to its canonical title."
  def localized_title(media, locale), do: localized_field(media, locale, :title)

  @doc "Returns the localized overview for `media`, falling back to its canonical overview."
  def localized_overview(media, locale), do: localized_field(media, locale, :overview)

  defp localized_field(nil, _locale, _field), do: nil

  defp localized_field(%{} = media, locale, field) do
    canonical = Map.get(media, field)
    key = Atom.to_string(field)

    case {locale == Locales.canonical(), Map.get(media, :localizations)} do
      {false, %{^locale => %{^key => value}}} when is_binary(value) and value != "" -> value
      _ -> canonical
    end
  end
end
