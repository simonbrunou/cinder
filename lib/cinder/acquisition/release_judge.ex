defmodule Cinder.Acquisition.ReleaseJudge do
  @moduledoc """
  The release judge for a movie, a TV season or an anime title: every parsed release an indexer
  search returned, each kept or dropped by a named stage, with the verdict and language fact the
  manual-search panel shows for it. The sweep takes its pick from the same record, so the panel
  can't list a release as acceptable that the sweep would never pick, or the other way round.

  The guard names the target and how its search was scoped:

  - `{:imdb, context}`: an IMDb-scoped movie search.
  - `{:title_year, title, year}`: a movie with no IMDb id.
  - `{:series, series, season_number, wanted_numbers}`: a standard TV season and its still-wanted
    episode numbers.
  - `{:anime_movie, context}`: an anime movie (`Cinder.Catalog.movie_acquisition_context/1`).
  - `{:anime_episodes, context, wanted_ids}`: the wanted episodes of an anime series, by stable
    episode id (`Cinder.Catalog.anime_series_acquisition_context/1`).

  `judge/3` runs these stages, in this order. An anime episode search has no title guard (its
  search guards its free-text results and the stable-id mapping holds the rest), and a stage of
  its own:

  1. **Protocol.** A release whose protocol has no download client (`:protocols` in the
     household policy) is dropped.
  2. **Title guard.** A release whose name isn't the target's is dropped
     (`Cinder.Acquisition.title_guard/2`). For anime episodes, **role** instead: a release the
     anime parser doesn't read as a story episode (a creditless opening, an OVA) is dropped.
  3. **Language.** The title's audio pick filters what is left (`Cinder.Acquisition.Language`).
     A strict pick (french, dual) that would drop every survivor gives `:no_language_match` and
     keeps nothing, so the movie parks visibly. A soft one (original, any) falls back to the
     survivors and drops none: the parser reads the language from the whole name, and a title
     word ("The Italian Job" → ITALIAN) must not strand a title under the default pick. The
     movie guards keep an untagged release under a soft pick, ranked below a tagged match
     (`Scorer.rank_key/2` is `Scorer.select/2`'s whole sort key, so it wins only when nothing
     tagged survives the band). A season doesn't. The set-cover would rank it the same way
     (`Scorer.select_for/4`), but keeping it changes which releases a season grabs, a product
     decision (ADR 0003, #882). Under an anime policy the stage is off: the policy judges audio
     from release evidence, not the name's tag.
  4. **Mapping**, anime episodes and standard seasons. An anime release that doesn't resolve to
     wanted stable episode ids, or whose mapping snapshot can't be frozen, is dropped: a grab
     could link no episode. A season release with an alternate-numbered coordinate that resolves
     two ways (`:conflicting_standard_numbering`, `Cinder.Acquisition.judge_season/3`) is dropped:
     a grab couldn't tell which episodes it holds.

  An anime movie's releases have their group read from the name first
  (`Cinder.Acquisition.Anime.movie_candidates/1`), as its policy reads it. An anime episode
  release is parsed and its mapping frozen first
  (`Cinder.Acquisition.Anime.episode_candidates/3`).

  `kept` is what the selection runs over, in indexer order: `Cinder.Acquisition.Scorer` breaks
  ties by input order. `pick/1` is the selection.

  Each row of `rows` carries:

  - `dropped_at`: the first stage that dropped the release, or nil if it was kept.
  - `verdict`: why automatic selection would skip it, which the panel shows and the operator may
    override. No client for the protocol comes first. Only the IMDb-scoped and anime movie
    guards say `:title_mismatch`; the Title.Year and season guards also reject for a missing
    year or the language before it, so they drop the row without a verdict of their own.
    `:conflicting_standard_numbering` marks a bridged coordinate that resolves two ways. An anime
    episode row with no frozen mapping is `:unsafe_anime_mapping` (the panel can't grab it), and
    one the role stage dropped is `:special_release` (the sweep never takes it; the operator
    may). The rest is the selection's own rules for one release: `Scorer.verdict/2` for a movie,
    `Scorer.verdict_for_season/4` for a season (the set-cover's band for that release alone, both
    passes of `Scorer.select_for/4` included), or for anime
    `Cinder.Acquisition.Anime.movie_verdict/2` and `episode_verdict/2` (policy, quality, group
    wait).
  - `audio`: what the language stage decided. `:match` when the release's tag satisfies the pick,
    at any stage. `:assumed` for an untagged release a movie pool kept. `:mismatch` for a release
    the language stage dropped. nil for a release dropped before that stage, when the pick fell
    back, and on every row when no pick is in force (`language: :off`).

  `rows` lists acceptable releases first, each group in rank order (`Scorer.rank_key/2`).

  Under an anime policy the judge pins `opts[:now]`, so a row's group-wait verdict and the pick
  read the same clock.
  """

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Anime, Language, Scorer}

  defstruct [:guard, rows: [], kept: [], language: :off, opts: []]

  @movie_guards [:imdb, :title_year, :anime_movie]
  @anime_guards [:anime_movie, :anime_episodes]

  @type guard ::
          {:imdb, map()}
          | {:title_year, String.t() | nil, integer() | nil}
          | {:series, map(), integer(), [integer()]}
          | {:anime_movie, map()}
          | {:anime_episodes, map(), [integer()]}
  @type stage :: :protocol | :title_guard | :role | :language | :mapping
  @type row :: %{
          release: struct(),
          dropped_at: nil | stage(),
          verdict: :ok | {:rejected, atom()},
          audio: nil | :match | :assumed | :mismatch
        }
  @type t :: %__MODULE__{
          guard: guard(),
          rows: [row()],
          kept: [struct()],
          language: :off | :applied | :fell_back | :no_language_match,
          opts: keyword()
        }

  @doc """
  Judges `releases` for the target `guard` names, under the household policy `opts`
  (`Cinder.Acquisition.HouseholdPolicy.for_target/2`, plus any per-search opts the selection reads and, for an
  anime guard, `anime_policy:`).
  """
  @spec judge([struct()], guard(), keyword()) :: t()
  def judge(releases, guard, opts) do
    opts = pin_clock(opts)
    releases = prepare(releases, guard)

    # Each stage's survivors, in stage order, and what the last one kept.
    {survivors_by_stage, {kept, language}} =
      Enum.map_reduce(stages(guard), {releases, :off}, fn
        :language, {pool, _off} ->
          {language, kept} = language_stage(pool, guard, opts)
          {{:language, MapSet.new(kept)}, {kept, language}}

        stage, {pool, language} ->
          kept = filter(stage, pool, guard, opts)
          {{stage, MapSet.new(kept)}, {kept, language}}
      end)

    target = Language.target(opts[:preferred_language], opts[:original_language])

    rows =
      releases
      |> Enum.map(&row(&1, dropped_at(&1, survivors_by_stage), guard, language, target, opts))
      |> Enum.sort_by(&{&1.verdict != :ok, Scorer.rank_key(&1.release, opts)})

    %__MODULE__{guard: guard, rows: rows, kept: kept, language: language, opts: opts}
  end

  @doc """
  What the sweep grabs. For a movie, the best-ranked kept release the selection accepts
  (`Scorer.select/2`, or `Cinder.Acquisition.Anime.select_movie/2` for an anime movie, which may
  instead wait for a preferred group), or `:no_language_match` when a strict audio pick left
  nothing to rank. For anime episodes, the stable-id cover over the kept releases
  (`Cinder.Acquisition.Anime.cover_episodes/3`); a strict audio pick that left nothing to cover
  is `:no_match` there. For a standard season, the set-cover over the kept releases
  (`Scorer.select_for/4`): each chosen release with the still-wanted episode numbers it covers,
  or `:no_match`, which is also what a strict audio pick that left nothing gives.
  """
  @spec pick(t()) ::
          {:ok, struct()}
          | :no_match
          | :no_language_match
          | {:waiting_for_preferred_group, map()}
          | {:ok, %{assignments: [map()], waiting: map() | nil}}
          | {:ok, [{struct(), [integer()]}]}
  def pick(%__MODULE__{guard: guard, language: :no_language_match})
      when elem(guard, 0) in @movie_guards,
      do: :no_language_match

  def pick(%__MODULE__{guard: {:anime_movie, _context}} = judged),
    do: Anime.select_movie(judged.kept, judged.opts)

  def pick(%__MODULE__{guard: {:anime_episodes, _context, wanted_ids}} = judged),
    do: Anime.cover_episodes(judged.kept, wanted_ids, judged.opts)

  def pick(%__MODULE__{guard: {:series, _series, season_number, wanted_numbers}} = judged),
    do: Scorer.select_for(judged.kept, season_number, wanted_numbers, judged.opts)

  def pick(%__MODULE__{guard: guard} = judged) when elem(guard, 0) in @movie_guards,
    do: Scorer.select(judged.kept, judged.opts)

  defp pin_clock(opts) do
    if Keyword.get(opts, :anime_policy),
      do: Keyword.put_new_lazy(opts, :now, &DateTime.utc_now/0),
      else: opts
  end

  defp prepare(releases, {:anime_movie, _context}), do: Anime.movie_candidates(releases)

  defp prepare(releases, {:anime_episodes, context, wanted_ids}),
    do: Anime.episode_candidates(releases, context, wanted_ids)

  defp prepare(releases, _guard), do: releases

  defp stages({:anime_episodes, _context, _wanted_ids}),
    do: [:protocol, :role, :language, :mapping]

  defp stages({:series, _series, _season_number, _wanted_numbers}),
    do: [:protocol, :title_guard, :language, :mapping]

  defp stages(_guard), do: [:protocol, :title_guard, :language]

  defp filter(:protocol, pool, _guard, opts),
    do: Enum.filter(pool, &client?(&1, Keyword.get(opts, :protocols)))

  defp filter(:title_guard, pool, guard, _opts), do: Acquisition.title_guard(pool, guard)
  defp filter(:role, pool, _guard, _opts), do: Enum.filter(pool, &(&1.role == :story))

  defp filter(:mapping, pool, {:series, _series, _season_number, _wanted_numbers}, _opts),
    do: Enum.reject(pool, &(&1.resolution_evidence == :conflicting_standard_numbering))

  defp filter(:mapping, pool, _guard, _opts), do: Enum.reject(pool, &is_nil(&1.mapping_snapshot))

  defp language_stage(candidates, guard, opts) do
    preferred = Keyword.get(opts, :preferred_language)
    original = Keyword.get(opts, :original_language)

    if anime_policy?(guard, opts) or is_nil(Language.target(preferred, original)) do
      {:off, candidates}
    else
      # Movie-only by product choice (see the Language stage above).
      filtered = Language.filter(candidates, preferred, original, keep_untagged: movie?(guard))
      language_outcome(candidates, filtered, Language.strict?(preferred))
    end
  end

  defp language_outcome([_ | _], [], true = _strict?), do: {:no_language_match, []}
  defp language_outcome([_ | _] = candidates, [], false = _strict?), do: {:fell_back, candidates}
  defp language_outcome(_candidates, filtered, _strict?), do: {:applied, filtered}

  defp anime_policy?(guard, opts),
    do: elem(guard, 0) in @anime_guards and not is_nil(opts[:anime_policy])

  defp client?(_release, nil), do: true
  defp client?(release, protocols), do: release.protocol in protocols

  defp movie?(guard), do: elem(guard, 0) in @movie_guards

  defp dropped_at(release, survivors_by_stage) do
    Enum.find_value(survivors_by_stage, fn {stage, survivors} ->
      if not MapSet.member?(survivors, release), do: stage
    end)
  end

  defp row(release, dropped_at, guard, language, target, opts) do
    %{
      release: release,
      dropped_at: dropped_at,
      verdict: verdict(release, dropped_at, guard, opts),
      audio: audio(release, dropped_at, language, target)
    }
  end

  defp verdict(_release, :protocol, _guard, _opts), do: {:rejected, :wrong_protocol}

  defp verdict(_release, :title_guard, {kind, _context}, _opts)
       when kind in [:imdb, :anime_movie],
       do: {:rejected, :title_mismatch}

  defp verdict(release, _dropped_at, {:anime_movie, _context}, opts),
    do: Anime.movie_verdict(release, opts)

  # A release with no frozen mapping names no stable episode ids a grab could link, so the panel
  # can't take it whatever else is true of it.
  defp verdict(%{mapping_snapshot: nil}, _dropped_at, {:anime_episodes, _, _}, _opts),
    do: {:rejected, :unsafe_anime_mapping}

  defp verdict(_release, :role, {:anime_episodes, _, _}, _opts),
    do: {:rejected, :special_release}

  defp verdict(release, _dropped_at, {:anime_episodes, _context, _wanted_ids}, opts),
    do: Anime.episode_verdict(release, opts)

  defp verdict(%{resolution_evidence: :conflicting_standard_numbering}, _dropped, _guard, _opts),
    do: {:rejected, :conflicting_standard_numbering}

  defp verdict(release, _dropped_at, {:series, _series, season_number, wanted_numbers}, opts),
    do: Scorer.verdict_for_season(release, season_number, wanted_numbers, opts)

  defp verdict(release, _dropped_at, _guard, opts), do: Scorer.verdict(release, opts)

  defp audio(_release, _dropped_at, :off, _target), do: nil

  defp audio(release, dropped_at, language, target) do
    cond do
      Language.satisfies_lang?(release.language, target) -> :match
      dropped_at in [:protocol, :title_guard, :role] or language == :fell_back -> nil
      dropped_at == :language -> :mismatch
      true -> :assumed
    end
  end
end
