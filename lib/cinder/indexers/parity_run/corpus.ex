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
  episode a manual search may act on (`Catalog.manual_search_episodes/2`: one no grab holds,
  either with a file or one the sweep would search, monitored, aired and with no file), and all
  of them are wanted, so an imported season is judged instead of returning `:no_match`. A
  standard season's wanted numbers are its searched episodes' numbers
  (`Catalog.season_acquisition_context/2`), its imported ones included.

  ## The draw

  Per kind, the candidates are read in id order and split into the imported ones (a movie
  `:available` or `:upgrading`, a season or anime season with an episode file, a book target
  `:available`) and the others; each group is shuffled by the seed, imported first, and the
  first `count` are taken. One `:rand` state, seeded once, runs through the kinds in the order
  above, so the same seed draws the same corpus from the same library. An anime series whose
  anime policy does not resolve (`AnimePreferences.resolve/2`) is not drawn.

  ## The counts

  One search of each kind at its worst costs a Newznab indexer at most 64 requests per source,
  128 for the pair (#1618 point 14). `planned_counts/1` gives each kind one search per 128
  requests of the per-indexer budget left once 72 are set aside for retries and the link check:
  one each at the default 200. The anime episodes and the movies by title and year, which Nyaa.si
  and Torrent9 take (#1624 point 8), run first, so a deadline or a spent budget cuts them last.
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
    :movie_title,
    :movie_imdb,
    :season,
    :season_zero,
    :ebook,
    :audiobook
  ]

  @pair_round 128
  @reserve 72

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
  The searches `counts` asks for, drawn with `seed`: `%{label, kind, target, policy}` each, in
  run order (see the moduledoc). `policy` is what the run builds the search's opts from.
  """
  @spec draw(integer(), %{atom() => non_neg_integer()}) :: [map()]
  def draw(seed, counts) do
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})

    {drawn, _state} =
      Enum.map_reduce(@kinds, state, fn kind, state ->
        {picked, state} = pick(candidates(kind), Map.get(counts, kind, 0), state)
        {{kind, Enum.flat_map(picked, &search(kind, &1))}, state}
      end)

    drawn = Map.new(drawn)
    Enum.flat_map(@run_order, &Map.fetch!(drawn, &1))
  end

  defp pick(_candidates, 0, state), do: {[], state}

  defp pick(candidates, count, state) do
    {imported, others} = Enum.split_with(candidates, &elem(&1, 0))
    {imported, state} = shuffle(Enum.map(imported, &elem(&1, 1)), state)
    {others, state} = shuffle(Enum.map(others, &elem(&1, 1)), state)
    {Enum.take(imported ++ others, count), state}
  end

  defp shuffle(list, state) do
    {keyed, state} =
      Enum.map_reduce(list, state, fn item, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, item}, state}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
  end

  # --- the candidates: `{imported?, item}` in id order ---

  defp candidates(:movie_imdb),
    do: for({imported?, movie} <- standard_movies(), movie.imdb_id, do: {imported?, movie})

  defp candidates(:movie_title), do: standard_movies()
  defp candidates(:season), do: seasons(:standard, &(&1 > 0))
  defp candidates(:season_zero), do: seasons(:standard, &(&1 == 0))
  # An anime series whose policy does not resolve gives no search, so it takes no draw.
  defp candidates(:anime_episodes) do
    defaults = Settings.anime_defaults()

    for {_imported?, {series, _number, _episodes}} = candidate <- seasons(:anime, &(&1 > 0)),
        match?({:ok, _policy}, AnimePreferences.resolve(series, defaults)),
        do: candidate
  end

  defp candidates(:ebook), do: book_targets(:ebook)
  defp candidates(:audiobook), do: book_targets(:audiobook)

  defp standard_movies do
    from(m in Movie, order_by: [asc: m.id])
    |> Repo.all()
    |> Enum.filter(&(Catalog.media_profile_summary(&1).effective == :standard))
    |> Enum.map(&{&1.status in [:available, :upgrading], &1})
  end

  defp seasons(profile, number?) do
    series =
      from(s in Series, order_by: [asc: s.id])
      |> Repo.all()
      |> Enum.filter(&(Catalog.media_profile_summary(&1).effective == profile))

    for series <- series,
        season <- Repo.all(from s in Season, where: s.series_id == ^series.id, order_by: s.id),
        number?.(season.season_number),
        episodes = Catalog.manual_search_episodes(series.id, season.season_number),
        episodes != [],
        do: {Enum.any?(episodes, &imported?/1), {series, season.season_number, episodes}}
  end

  defp imported?(%Episode{file_path: path}), do: is_binary(path)

  defp book_targets(kind) do
    from(t in BookTarget, where: t.media_kind == ^kind, order_by: [asc: t.id])
    |> Repo.all()
    |> Enum.map(&{&1.status == :available, &1})
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
