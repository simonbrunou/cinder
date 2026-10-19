defmodule Cinder.Requests.Target do
  @moduledoc """
  Resolves requests to their request targets.

  A request names its target by `target_type` + `target_id`, and the id means something different
  per type: a movie's TMDB id for `"movie"`, the series' TMDB id (plus `season_number`) for
  `"season"`, and a local `book_works.id` (plus `media_kind`) for `"book"`. The ids collide across
  types, so a map of requests or targets is keyed by the typed key `key/1` returns, never by the
  raw `target_id`. Queries that already filter on `target_type` (the approved-requester lookups,
  `Cinder.Issues.open_report?/3`) don't need it.

  Each summary answers two questions, which deliberately differ:

    * `watchable?`: the household can watch it on the media server now. My requests ("Open in",
      "Report an issue"), the Discover and movie-page badge, and `Cinder.Issues` all read it.
    * `outstanding?`: an approved request on it still holds a quota slot. It is broader than "not
      watchable": a cancelled movie, an upgrade held for verification, an unmonitored season and a
      paused book are settled without being watchable.
  """
  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Season, Series}
  alias Cinder.LibraryKind
  alias Cinder.Repo

  @type key ::
          {:movie, integer()}
          | {:season, integer(), integer()}
          | {:book, integer(), :ebook | :audiobook}
          | {:unsupported, term(), term()}

  @typedoc "Any map carrying the target columns: a request, an issue report, or an attrs map."
  @type ref :: %{
          required(:target_type) => term(),
          required(:target_id) => term(),
          optional(:season_number) => term(),
          optional(:media_kind) => term(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          key: key(),
          watchable?: boolean(),
          outstanding?: boolean(),
          title: String.t() | nil,
          media_server_item_id: String.t() | nil,
          movie: %Movie{} | nil,
          season_progress:
            %{total: integer(), available: integer(), downloading: boolean()} | nil,
          book_status: atom() | nil
        }

  defstruct key: nil,
            watchable?: false,
            outstanding?: true,
            title: nil,
            media_server_item_id: nil,
            movie: nil,
            season_progress: nil,
            book_status: nil

  @book_media_kinds LibraryKind.books()

  # A movie whose library file plays now. An upgrade keeps the old file until the new one lands.
  @watchable_movie_statuses [:available, :upgrading]

  @doc "The typed target key for `ref`. Pure: no database read."
  @spec key(ref()) :: key()
  def key(%{target_type: "movie", target_id: id}) when is_integer(id), do: {:movie, id}

  def key(%{target_type: "season", target_id: id, season_number: n})
      when is_integer(id) and is_integer(n),
      do: {:season, id, n}

  def key(%{target_type: "book", target_id: id, media_kind: kind})
      when is_integer(id) and kind in @book_media_kinds,
      do: {:book, id, kind}

  def key(%{target_type: type, target_id: id}), do: {:unsupported, type, id}

  @doc """
  Pairs each ref with its target's current state, in input order. Reads only the targets the refs
  name, one batch per target type, with plain reads, so it is safe inside an open transaction.
  """
  @spec resolve([ref()]) :: [{ref(), t()}]
  def resolve(refs) do
    keys = Enum.map(refs, &key/1)
    loaded = load_movies(keys) |> Map.merge(load_seasons(keys)) |> Map.merge(load_books(keys))

    Enum.zip_with(refs, keys, fn ref, key -> {ref, summarize(key, loaded)} end)
  end

  @doc """
  Whether a movie at `status` is watchable. Public for Discover, whose movie cards carry only a
  status per TMDB id: the card badge and `resolve/1` run this same rule.
  """
  @spec watchable_movie_status?(atom() | nil) :: boolean()
  def watchable_movie_status?(status), do: status in @watchable_movie_statuses

  defp summarize({:movie, id} = key, %{movies: movies}) do
    case movies[id] do
      nil ->
        %__MODULE__{key: key}

      movie ->
        %__MODULE__{
          key: key,
          movie: movie,
          title: movie.title,
          media_server_item_id: movie.media_server_item_id,
          watchable?: watchable_movie_status?(movie.status),
          outstanding?: movie_outstanding?(movie)
        }
    end
  end

  defp summarize({:season, id, n} = key, loaded) do
    series = loaded.series[id]
    landed? = MapSet.member?(loaded.landed, {id, n})

    %__MODULE__{
      key: key,
      title: series && series.title,
      media_server_item_id: series && series.media_server_item_id,
      season_progress: loaded.progress[{id, n}],
      watchable?: landed?,
      outstanding?: season_outstanding?(loaded.monitored[{id, n}], landed?)
    }
  end

  # Never watchable: a book lands in Booklore or Audiobookshelf, which neither Issues nor the media
  # server link covers. Pausing a target (`:unmonitored`) settles the request.
  defp summarize({:book, work_id, kind} = key, %{books: books}) do
    status = books[{work_id, kind}]

    %__MODULE__{
      key: key,
      book_status: status,
      outstanding?: status not in [:available, :unmonitored]
    }
  end

  # `"series"`, `"episode"` and malformed refs: never read, never watchable, and outstanding, so
  # the quota fails closed on a target type nothing writes yet.
  defp summarize(key, _loaded), do: %__MODULE__{key: key}

  # The quota's rule, deliberately broader than watchable: a landed movie stops holding a slot,
  # and so does one an operator settled. An upgrade held for verification still has its old file,
  # so it counts as landed even though no surface offers it as watchable while an operator decides.
  defp movie_outstanding?(%Movie{verification_hold_origin: :upgrade}), do: false
  defp movie_outstanding?(%Movie{status: :cancelled}), do: false
  defp movie_outstanding?(%Movie{status: status}), do: not watchable_movie_status?(status)

  # Only a monitored season row still waits: unmonitoring settles it (`cancel_series/2` unmonitors
  # the whole tree). A season with no row at all is not outstanding either. That is how the quota
  # counted before this module existed, and changing it is a quota decision, not a refactor.
  defp season_outstanding?(true = _monitored, landed?), do: not landed?
  defp season_outstanding?(_monitored, _landed?), do: false

  defp load_movies(keys) do
    case for({:movie, id} <- keys, uniq: true, do: id) do
      [] ->
        %{movies: %{}}

      ids ->
        movies = Repo.all(from m in Movie, where: m.tmdb_id in ^ids)
        %{movies: Map.new(movies, &{&1.tmdb_id, &1})}
    end
  end

  defp load_seasons(keys) do
    case for({:season, id, _n} <- keys, uniq: true, do: id) do
      [] ->
        %{series: %{}, monitored: %{}, landed: MapSet.new(), progress: %{}}

      ids ->
        %{
          series:
            Repo.all(from s in Series, where: s.tmdb_id in ^ids) |> Map.new(&{&1.tmdb_id, &1}),
          monitored:
            Repo.all(
              from s in Season,
                join: sr in assoc(s, :series),
                where: sr.tmdb_id in ^ids,
                select: {{sr.tmdb_id, s.season_number}, s.monitored}
            )
            |> Map.new(),
          landed: Catalog.available_season_keys(ids),
          progress: Catalog.season_progress_keys(ids)
        }
    end
  end

  defp load_books(keys) do
    work_ids = for {:book, id, _kind} <- keys, uniq: true, do: id
    %{books: Books.target_statuses(work_ids)}
  end
end
