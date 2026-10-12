defmodule Cinder.Library.EpisodeSources do
  @moduledoc """
  Picks one import source per episode from a standard-TV download, and reports the leftover videos.

  The input is `Cinder.Library`'s `{episode, path, size}` claims (a double-episode file yields one
  claim per episode) plus every video in the download. A leftover becomes an operator decision on
  /activity, so a sample-named file (`MovieSources.sample_name?/2`) that lost every episode it
  claims to a real file is dropped (logged) instead: it is the release's preview clip, not an
  unidentified video.
  """

  require Logger

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog.Episode
  alias Cinder.Library.MovieSources

  @doc "Returns `{[{episode, source_path}], unmatched_paths}`."
  @spec pick(
          [{Episode.t(), String.t(), non_neg_integer()}],
          [{String.t(), non_neg_integer()}],
          [Episode.t()]
        ) :: {[{Episode.t(), String.t()}], [String.t()]}
  def pick(matches, videos, episodes) do
    matches
    |> dedupe_per_episode()
    |> resolve(videos, episodes)
  end

  # One source per episode: prefer a non-sample-named candidate via `MovieSources.sample_name?/2`,
  # falling back to largest-wins only when every candidate is sample-named; path breaks ties for a
  # dest stable across retries. Losers fall through to `resolve` as unmatched (logged) — never
  # link two different sources onto one episode's dest (the second would collide). Group by
  # episode, not source, so a double-episode file still maps to both.
  #
  # Returns `{winners, superseded}`: `superseded` is every sample-named file whose episodes ALL
  # went to a real file, which `resolve` drops instead of reporting unmatched.
  defp dedupe_per_episode(matches) do
    groups = Enum.group_by(matches, fn {ep, _path, _size} -> ep.id end)

    winners =
      Enum.map(groups, fn {_id, group} ->
        real = Enum.reject(group, &sample_match?/1)
        candidates = if real == [], do: group, else: real
        {ep, path, _size} = Enum.max_by(candidates, fn {_e, p, s} -> {s, p} end)
        {ep, path}
      end)

    {winners, superseded_samples(matches, groups)}
  end

  defp superseded_samples(matches, groups) do
    won_by_real =
      for {id, group} <- groups,
          not Enum.all?(group, &sample_match?/1),
          into: MapSet.new(),
          do: id

    matches
    |> Enum.filter(&sample_match?/1)
    |> Enum.group_by(fn {_ep, path, _size} -> path end, fn {ep, _path, _size} -> ep.id end)
    |> Enum.filter(fn {_path, ids} -> Enum.all?(ids, &MapSet.member?(won_by_real, &1)) end)
    |> Enum.map(fn {path, _ids} -> path end)
  end

  defp sample_match?({_ep, path, size}), do: MovieSources.sample_name?(path, size)

  # Decide the import set + the leftover (unmatched) video files for logging.
  defp resolve({[], []}, videos, episodes) do
    if single_ep_fallback?(episodes, videos) do
      # Largest wins; path breaks ties so the dest is stable across retries. When the winner is a
      # real file, the losing samples are dropped like `dedupe_per_episode`'s; extras stay unmatched.
      winner = Enum.max_by(videos, fn {p, size} -> {size, p} end)
      losers = List.delete(videos, winner)

      {[{hd(episodes), elem(winner, 0)}],
       drop_superseded(paths(losers), samples_beaten(winner, losers))}
    else
      {[], paths(videos)}
    end
  end

  defp resolve({matched, superseded}, videos, _episodes) do
    matched_paths = matched |> Enum.map(fn {_ep, p} -> p end) |> MapSet.new()
    unmatched = Enum.reject(paths(videos), &MapSet.member?(matched_paths, &1))
    {matched, drop_superseded(unmatched, superseded)}
  end

  defp samples_beaten({path, size}, losers) do
    if MovieSources.sample_name?(path, size),
      do: [],
      else: for({p, s} <- losers, MovieSources.sample_name?(p, s), do: p)
  end

  defp drop_superseded(unmatched, []), do: unmatched

  defp drop_superseded(unmatched, superseded) do
    Logger.info(
      "import: dropped #{length(superseded)} sample file(s) superseded by a real file: " <>
        inspect(Enum.map(superseded, &Path.basename/1))
    )

    unmatched -- superseded
  end

  # Fall back to largest-wins only for a lone-episode grab whose files name NO specific episode
  # (so we never mistake a clearly-numbered other episode for ours). See
  # Cinder.Library.AnimePreflight.infer_lone_file/3 for anime's stricter analogue.
  defp single_ep_fallback?([_one], [_ | _] = videos),
    do: Enum.all?(videos, fn {p, _size} -> is_nil(Parser.parse(Path.basename(p)).episodes) end)

  defp single_ep_fallback?(_episodes, _videos), do: false

  defp paths(videos), do: Enum.map(videos, fn {p, _size} -> p end)
end
