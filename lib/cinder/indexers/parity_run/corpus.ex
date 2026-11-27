defmodule Cinder.Indexers.ParityRun.Corpus do
  @moduledoc """
  The searches of one parity run (`Cinder.Indexers.ParityRun`, #1624 point 8 and amendment
  change 1), drawn from the library at run time by a seed.

  ## The kinds

  | Kind | Drawn from | Caller's target |
  | --- | --- | --- |
  | `:movie_imdb` | standard movies with an IMDb id | `imdb_id`, `Catalog.movie_acquisition_context/1` |
  | `:movie_title` | standard movies, searched with a nil id | as above |
  | `:season` | seasons above 0 of standard series | `Catalog.season_acquisition_context/2`, every searched episode |
  | `:season_zero` | season 0 of standard series | as above |
  | `:anime_episodes` | seasons above 0 of anime series | `Catalog.anime_series_acquisition_context/1`, every aired episode of the season |
  | `:ebook`, `:audiobook` | e-book and audiobook targets | `Books.get_work/1` |

  A title is standard or anime by `Catalog.media_profile_summary/1`'s `effective` profile, as the
  sweeps and the manual search read it. A season or an anime season is drawn only when it has an
  episode a manual search may act on (`Catalog.manual_search_episodes/3`: one no grab holds,
  either with a file or one the sweep would search, monitored, aired and with no file), and all
  of them are wanted, so an imported season is judged instead of returning `:no_match`. A
  standard season's wanted numbers are its searched episodes' numbers
  (`Catalog.season_acquisition_context/2`), its imported ones included.

  ## The draw

  Per kind, the candidates are read in id order and split into the imported ones (a movie
  `:available` or `:upgrading`, a season or anime season with an episode file, a book target
  `:available`) and the others. A `:season` candidate that airs now goes into a third group
  before both (#1971): one with an episode whose `air_date`, the household date it aired, falls
  from 30 days before the run's date to that date, both ends included. The run's date is the
  household date (`Settings.household_date/1`) of the `now` the run passes to `draw/3`, and the
  episodes a manual search may act on are read at that date too. On #1944's probe Torrent9
  answered one such season and none of the three movies by title and year it tried. Each group
  is shuffled by the seed, in that order, and the first `count` are taken. One `:rand` state,
  seeded once, runs through the kinds in the order above, so the same seed draws the same corpus
  from the same library on the same date. An anime series whose anime policy does not resolve
  (`AnimePreferences.resolve/2`) is not drawn.

  ## The counts

  One search of each kind at its worst costs a Newznab indexer at most 64 requests per source,
  128 for the pair (#1618 point 14). `planned_counts/1` gives each kind one search per 128
  requests of the per-indexer budget left once 72 are set aside for retries and the link check:
  one each at the default 200. The kinds Nyaa.si and Torrent9 answer run first, so a deadline or
  a spent budget cuts them last: the anime episodes (#1624 point 8), then the seasons, which
  #1971 put in place of the movies by title and year that #1624 point 8 favoured for Torrent9,
  then the movies.
  """

  import Ecto.Query, only: [from: 2]

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Repo
  alias Cinder.Settings

  @kinds [:movie_imdb, :movie_title, :season, :season_zero, :anime_episodes, :ebook, :audiobook]

  # The order the run searches the kinds in: the favoured ones first.
  @run_order [
    :anime_episodes,
    :season,
    :movie_title,
    :movie_imdb,
    :season_zero,
    :ebook,
    :audiobook
  ]

  @pair_round 128
  @reserve 72
  @recent_days 30

  @doc "The kinds a run draws, in draw order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The searches per kind a budget of `budget` requests per indexer plans. See the moduledoc."
  @spec planned_counts(non_neg_integer()) :: %{atom() => non_neg_integer()}
  def planned_counts(budget) do
    rounds = max(div(budget - @reserve, @pair_round), 0)
    Map.new(@kinds, &{&1, rounds})
  end

  @doc """
  The searches `counts` asks for, drawn with `seed` at the run's `now`: `%{label, kind, target,
  policy}` each, in run order (see the moduledoc). `policy` is what the run builds the search's
  opts from.
  """
  @spec draw(integer(), %{atom() => non_neg_integer()}, DateTime.t()) :: [map()]
  def draw(seed, counts, now) do
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    today = Settings.household_date(now)

    {drawn, _state} =
      Enum.map_reduce(@kinds, state, fn kind, state ->
        {picked, state} = pick(candidates(kind, today), Map.get(counts, kind, 0), state)
        {{kind, Enum.flat_map(picked, &search(kind, &1))}, state}
      end)

    drawn = Map.new(drawn)
    Enum.flat_map(@run_order, &Map.fetch!(drawn, &1))
  end

  defp pick(_candidates, 0, state), do: {[], state}

  defp pick(candidates, count, state) do
    {picked, state} =
      Enum.flat_map_reduce([:recent, :imported, :other], state, fn group, state ->
        shuffle(for({^group, item} <- candidates, do: item), state)
      end)

    {Enum.take(picked, count), state}
  end

  defp shuffle(list, state) do
    {keyed, state} =
      Enum.map_reduce(list, state, fn item, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, item}, state}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
  end

  # --- the candidates: `{group, item}` in id order, `group` `:recent`, `:imported` or `:other` ---

  defp candidates(:movie_imdb, _today),
    do: for({group, movie} <- standard_movies(), movie.imdb_id, do: {group, movie})

  defp candidates(:movie_title, _today), do: standard_movies()

  defp candidates(:season, today) do
    for {group, {_series, _number, season, _episodes} = item} <-
          seasons(:standard, &(&1 > 0), today),
        do: {if(recent?(season, today), do: :recent, else: group), drop_season(item)}
  end

  defp candidates(:season_zero, today),
    do:
      for({group, item} <- seasons(:standard, &(&1 == 0), today), do: {group, drop_season(item)})

  # An anime series whose policy does not resolve gives no search, so it takes no draw.
  defp candidates(:anime_episodes, today) do
    defaults = Settings.anime_defaults()

    for {group, {series, _number, _season, _episodes} = item} <-
          seasons(:anime, &(&1 > 0), today),
        match?({:ok, _policy}, AnimePreferences.resolve(series, defaults)),
        do: {group, drop_season(item)}
  end

  defp candidates(:ebook, _today), do: book_targets(:ebook)
  defp candidates(:audiobook, _today), do: book_targets(:audiobook)

  defp standard_movies do
    from(m in Movie, order_by: [asc: m.id])
    |> Repo.all()
    |> Enum.filter(&(Catalog.media_profile_summary(&1).effective == :standard))
    |> Enum.map(&{imported_group(&1.status in [:available, :upgrading]), &1})
  end

  defp seasons(profile, number?, today) do
    series =
      from(s in Series, order_by: [asc: s.id])
      |> Repo.all()
      |> Enum.filter(&(Catalog.media_profile_summary(&1).effective == profile))

    for series <- series,
        season <- Repo.all(from s in Season, where: s.series_id == ^series.id, order_by: s.id),
        number?.(season.season_number),
        episodes = Catalog.manual_search_episodes(series.id, season.season_number, today),
        episodes != [],
        do:
          {imported_group(Enum.any?(episodes, &imported?/1)),
           {series, season.season_number, season, episodes}}
  end

  defp drop_season({series, number, _season, episodes}), do: {series, number, episodes}

  # A season with an episode whose `air_date` falls from 30 days before `today` to `today`, both
  # ends included (#1971).
  defp recent?(%Season{id: id}, today) do
    first = Date.add(today, -@recent_days)

    Repo.exists?(
      from e in Episode,
        where: e.season_id == ^id and e.air_date >= ^first and e.air_date <= ^today
    )
  end

  defp imported?(%Episode{file_path: path}), do: is_binary(path)

  defp imported_group(true), do: :imported
  defp imported_group(false), do: :other

  defp book_targets(kind) do
    from(t in BookTarget, where: t.media_kind == ^kind, order_by: [asc: t.id])
    |> Repo.all()
    |> Enum.map(&{imported_group(&1.status == :available), &1})
  end

  # --- one search per drawn item ---

  defp search(kind, %Movie{} = movie) do
    context = Catalog.movie_acquisition_context(movie)

    [
      %{
        kind: kind,
        label: "#{kind} movie ##{movie.id} #{movie.title} (#{movie.year})",
        target: %{imdb_id: movie.imdb_id, context: context},
        policy: {:title, movie}
      }
    ]
  end

  defp search(:anime_episodes, {series, number, episodes}) do
    case AnimePreferences.resolve(series, Settings.anime_defaults()) do
      {:ok, policy} ->
        [
          %{
            kind: :anime_episodes,
            label: "anime_episodes series ##{series.id} #{series.title} season #{number}",
            target: %{
              context: Catalog.anime_series_acquisition_context(series),
              wanted_ids: Enum.map(episodes, & &1.id)
            },
            policy: {:anime, series, policy}
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp search(kind, {series, number, _episodes}) do
    context = Catalog.season_acquisition_context(series, number)

    [
      %{
        kind: kind,
        label: "#{kind} series ##{series.id} #{series.title} season #{number}",
        target: %{
          context: context,
          wanted_numbers: Enum.map(context.episodes, & &1.episode_number)
        },
        policy: {:title, series}
      }
    ]
  end

  defp search(kind, %BookTarget{} = target) do
    case Books.get_work(target.work_id) do
      nil ->
        []

      work ->
        [
          %{
            kind: kind,
            label: "#{kind} target ##{target.id} #{work.title}",
            target: %{work: work},
            policy: {:book, target}
          }
        ]
    end
  end
end
