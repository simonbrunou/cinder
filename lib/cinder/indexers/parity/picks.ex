defmodule Cinder.Indexers.Parity.Picks do
  @moduledoc """
  The callers the parity check (`Cinder.Indexers.Parity`) runs again over recorded rows, and the
  key two picks are compared by.

  `run/4` runs one search's caller with a source as `indexer_source:` and the search's opts as
  given, so a `now:` there reaches the caller; it sets none itself. #1684's recording sources
  call it to record a side's result; the check calls it with
  `Cinder.Indexers.Parity.Replay` (`replay/3`). It answers the pick's key (`key/2`).

  | Kind | Caller | Pick |
  | --- | --- | --- |
  | `:movie_imdb` | `Cinder.Acquisition.judge_movie/3` with the id | `ReleaseJudge.pick/1` |
  | `:movie_title` | `judge_movie/3` with a nil id | `ReleaseJudge.pick/1` |
  | `:anime_movie` | `Cinder.Acquisition.judge_anime_movie/3` | `ReleaseJudge.pick/1` |
  | `:season`, `:season_zero` | `Cinder.Acquisition.judge_season/3` | `ReleaseJudge.pick/1` |
  | `:anime_episodes` | `Cinder.Acquisition.judge_anime_episodes/3` | `ReleaseJudge.pick/1` |
  | `:ebook` | `Cinder.Acquisition.Ebooks.candidates/2` | its `accepted` list |
  | `:audiobook` | `Cinder.Acquisition.Audiobooks.candidates/2` | its `accepted` list |

  `target` holds the caller's arguments: `imdb_id` and `context` for the movies, `context` and
  `wanted_numbers` for a season, `context` and `wanted_ids` for anime episodes, `work` for books.

  ## The key

  Two releases match when their title, size (nil read as 0) and `Scorer.rank_key/2` under the
  search's opts are equal, so the same release from another indexer or link matches (#1624 point
  11). A movie pick is its release; a season pick the set of its releases, each with the episode
  numbers it covers; an anime episode pick the set of its assignments, each release with its
  episode ids, and its group wait (episode ids and end, to the second); books the multiset of
  accepted `{title, size}` and the top one. `:no_match`, `:no_language_match` and a group wait stay as
  they are, and an error keeps only its tag (`tag/1`).
  """

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Audiobooks, Ebooks, Release, ReleaseJudge, Scorer}
  alias Cinder.Indexers.Parity.Replay

  @kinds [
    :movie_imdb,
    :movie_title,
    :anime_movie,
    :season,
    :season_zero,
    :anime_episodes,
    :ebook,
    :audiobook
  ]

  @doc "The corpus kinds of #1624 point 8, plus the anime movie."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Runs the search's caller through `source`; answers the pick's key. See the moduledoc."
  @spec run(atom(), map(), keyword(), module()) :: term()
  def run(kind, target, opts, source) when kind in @kinds do
    caller_opts = Keyword.put(opts, :indexer_source, source)
    kind |> call(target, caller_opts) |> key(opts)
  end

  @doc """
  `run/4` through `Cinder.Indexers.Parity.Replay` over `calls`: `{key, replay_outcome}`. A
  caller that raises answers `{{:error, :raised}, outcome}`.
  """
  @spec replay(map(), keyword(), [map()]) :: {term(), Replay.outcome()}
  def replay(%{kind: kind, target: target}, opts, calls) do
    Replay.run(calls, fn ->
      try do
        run(kind, target, opts, Replay)
      rescue
        _exception -> {:error, :raised}
      end
    end)
  end

  defp call(kind, target, opts) when kind in [:movie_imdb, :movie_title] do
    imdb_id = if kind == :movie_imdb, do: target.imdb_id

    with {:ok, judged} <- Acquisition.judge_movie(imdb_id, target.context, opts),
         do: ReleaseJudge.pick(judged)
  end

  defp call(:anime_movie, target, opts) do
    with {:ok, judged, _incomplete?} <-
           Acquisition.judge_anime_movie(target.imdb_id, target.context, opts),
         do: ReleaseJudge.pick(judged)
  end

  defp call(kind, target, opts) when kind in [:season, :season_zero] do
    with {:ok, judged} <- Acquisition.judge_season(target.context, target.wanted_numbers, opts),
         do: ReleaseJudge.pick(judged)
  end

  defp call(:anime_episodes, target, opts) do
    with {:ok, judged, _incomplete?} <-
           Acquisition.judge_anime_episodes(target.context, target.wanted_ids, opts),
         do: ReleaseJudge.pick(judged)
  end

  defp call(:ebook, target, opts), do: books(Ebooks.candidates(target.work, opts))
  defp call(:audiobook, target, opts), do: books(Audiobooks.candidates(target.work, opts))

  defp books({:ok, %{accepted: accepted}}), do: {:books, Enum.map(accepted, &elem(&1, 0))}
  defp books(error), do: error

  @doc "The key of a pick under `opts`. See the moduledoc."
  @spec key(term(), keyword()) :: term()
  def key({:ok, %Release{} = release}, opts), do: {:release, release_key(release, opts)}

  def key({:ok, selections}, opts) when is_list(selections),
    do:
      {:season,
       Enum.sort(
         for {release, numbers} <- selections,
             do: {release_key(release, opts), Enum.sort(numbers)}
       )}

  def key({:ok, %{assignments: assignments, waiting: waiting}}, opts),
    do:
      {:anime,
       Enum.sort(
         for a <- assignments, do: {release_key(a.release, opts), Enum.sort(a.episode_ids)}
       ), waiting_key(waiting)}

  def key({:waiting_for_preferred_group, waiting}, _opts), do: {:waiting, waiting_key(waiting)}

  def key({:books, accepted}, _opts) do
    keys = Enum.map(accepted, &{&1.title, &1.size || 0})
    {:books, Enum.sort(keys), List.first(keys)}
  end

  def key(atom, _opts) when atom in [:no_match, :no_language_match], do: atom
  def key({:error, reason}, _opts), do: {:error, tag(reason)}
  def key(_other, _opts), do: {:error, :unexpected_pick}

  defp release_key(release, opts),
    do: {release.title, release.size || 0, Scorer.rank_key(release, opts)}

  defp waiting_key(nil), do: nil

  # One instant read at two precisions (`~U[10:00:00Z]`, `~U[10:00:00.000000Z]`) is the same
  # wait end: compare it to the second.
  defp waiting_key(waiting),
    do: {Enum.sort(Map.get(waiting, :episode_ids, [])), second(Map.get(waiting, :retry_at))}

  defp second(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp second(other), do: other

  @doc """
  An error reason reduced to a closed tag: an atom stays, a tuple keeps its leading atom and an
  integer second element (`{:http_status, 401}`), anything else is `:other`. A tag never holds a
  string, so it cannot carry a URL or a key.
  """
  @spec tag(term()) :: atom() | {atom(), integer()}
  def tag(reason) when is_atom(reason), do: reason
  def tag({tag, code}) when is_atom(tag) and is_integer(code), do: {tag, code}
  def tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  def tag(_reason), do: :other
end
