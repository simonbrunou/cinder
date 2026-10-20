defmodule Cinder.Acquisition.ReleaseJudge do
  @moduledoc """
  The release judge for a movie or a TV season: every parsed release an indexer search returned,
  each kept or dropped by a named stage, with the verdict and language fact the manual-search
  panel shows for it. The sweep takes its pick from the same record, so the panel can't list a
  release as acceptable that the sweep would never pick, or the other way round.

  `judge/3` runs the same stages, in the same order, for every search:

  1. **Protocol.** A release whose protocol has no download client (`:protocols` in the
     household policy) is dropped.
  2. **Title guard.** A release whose name isn't the target's is dropped. The guard depends on
     how the search was scoped: `{:imdb, context}` for an IMDb-scoped movie search,
     `{:title_year, title, year}` for a movie with no IMDb id, `{:series, series}` for a season.
     See `Cinder.Acquisition.title_guard/2`.
  3. **Language.** The title's audio pick filters what is left (`Cinder.Acquisition.Language`).
     A strict pick (french, dual) that would drop every survivor gives `:no_language_match` and
     keeps nothing, so the movie parks visibly. A soft one (original, any) falls back to the
     survivors and drops none: the parser reads the language from the whole name, and a title
     word ("The Italian Job" → ITALIAN) must not strand a title under the default pick. The
     movie guards keep an untagged release under a soft pick, ranked below a tagged match
     (`Scorer.rank_key/2` is `Scorer.select/2`'s whole sort key, so it wins only when nothing
     tagged survives the band). A season doesn't: the set-cover sorts by coverage before rank
     and would let an untagged pack beat confirmed-original singles.

  `kept` is what the selection runs over, in indexer order: `Cinder.Acquisition.Scorer` breaks
  ties by input order. For a movie, `pick/1` is the selection. For a season,
  `Cinder.Acquisition.best_releases/4` runs the set-cover over `kept`.

  Each row of `rows` carries:

  - `dropped_at`: the first stage that dropped the release, or nil if it was kept.
  - `verdict`: why automatic selection would skip it, which the panel shows and the operator may
    override. No client for the protocol comes first. Only the IMDb-scoped guard says
    `:title_mismatch`; the Title.Year and season guards also reject for a missing year or the
    language before it, so they drop the row without a verdict of their own.
    `:conflicting_standard_numbering` marks a bridged coordinate that resolves two ways. The rest
    is `Scorer.verdict/2`; for a season it bands a pack by `:pack_episode_count`, an
    approximation of the cover's still-wanted count.
  - `audio`: what the language stage decided. `:match` when the release's tag satisfies the pick,
    at any stage. `:assumed` for an untagged release a movie pool kept. `:mismatch` for a release
    the language stage dropped. nil for a release dropped before that stage, when the pick fell
    back, and on every row when no pick is in force (`language: :off`).

  `rows` lists acceptable releases first, each group in rank order (`Scorer.rank_key/2`).
  """

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Language, Scorer}

  defstruct [:guard, rows: [], kept: [], language: :off, opts: []]

  @type guard ::
          {:imdb, map()} | {:title_year, String.t() | nil, integer() | nil} | {:series, map()}
  @type row :: %{
          release: struct(),
          dropped_at: nil | :protocol | :title_guard | :language,
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
  (`Cinder.Acquisition.HouseholdPolicy.for_target/2`, plus any per-search scorer opts).
  """
  @spec judge([struct()], guard(), keyword()) :: t()
  def judge(releases, guard, opts) do
    on_protocol = Enum.filter(releases, &client?(&1, Keyword.get(opts, :protocols)))
    guarded = Acquisition.title_guard(on_protocol, guard)
    {language, kept} = language_stage(guarded, opts, keep_untagged: movie?(guard))

    stages = %{
      on_protocol: MapSet.new(on_protocol),
      guarded: MapSet.new(guarded),
      kept: MapSet.new(kept)
    }

    target = Language.target(opts[:preferred_language], opts[:original_language])

    rows =
      releases
      |> Enum.map(&row(&1, dropped_at(&1, stages), guard, language, target, opts))
      |> Enum.sort_by(&{&1.verdict != :ok, Scorer.rank_key(&1.release, opts)})

    %__MODULE__{guard: guard, rows: rows, kept: kept, language: language, opts: opts}
  end

  @doc """
  The movie the sweep grabs: the best-ranked kept release that passes `Scorer`'s rules, or
  `:no_language_match` when a strict audio pick left nothing to rank.
  """
  @spec pick(t()) :: {:ok, struct()} | :no_match | :no_language_match
  def pick(%__MODULE__{guard: guard, language: language} = judged)
      when elem(guard, 0) in [:imdb, :title_year] do
    if language == :no_language_match,
      do: :no_language_match,
      else: Scorer.select(judged.kept, judged.opts)
  end

  @doc """
  The language stage alone, for the anime pools that don't go through `judge/3` yet (#775):
  `{outcome, kept}` under the same strict and soft rules. `filter_opts` go to
  `Cinder.Acquisition.Language.filter/4`.
  """
  @spec language_stage([struct()], keyword(), keyword()) ::
          {:off | :applied | :fell_back | :no_language_match, [struct()]}
  def language_stage(candidates, opts, filter_opts) do
    preferred = Keyword.get(opts, :preferred_language)
    original = Keyword.get(opts, :original_language)

    if is_nil(Language.target(preferred, original)) do
      {:off, candidates}
    else
      filtered = Language.filter(candidates, preferred, original, filter_opts)
      language_outcome(candidates, filtered, Language.strict?(preferred))
    end
  end

  defp language_outcome([_ | _], [], true = _strict?), do: {:no_language_match, []}
  defp language_outcome([_ | _] = candidates, [], false = _strict?), do: {:fell_back, candidates}
  defp language_outcome(_candidates, filtered, _strict?), do: {:applied, filtered}

  defp client?(_release, nil), do: true
  defp client?(release, protocols), do: release.protocol in protocols

  defp movie?({:series, _series}), do: false
  defp movie?(_movie_guard), do: true

  defp dropped_at(release, stages) do
    cond do
      not MapSet.member?(stages.on_protocol, release) -> :protocol
      not MapSet.member?(stages.guarded, release) -> :title_guard
      not MapSet.member?(stages.kept, release) -> :language
      true -> nil
    end
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
  defp verdict(_release, :title_guard, {:imdb, _}, _opts), do: {:rejected, :title_mismatch}

  defp verdict(%{resolution_evidence: :conflicting_standard_numbering}, _dropped, _guard, _opts),
    do: {:rejected, :conflicting_standard_numbering}

  defp verdict(release, _dropped_at, _guard, opts), do: Scorer.verdict(release, opts)

  defp audio(_release, _dropped_at, :off, _target), do: nil

  defp audio(release, dropped_at, language, target) do
    cond do
      Language.satisfies_lang?(release.language, target) -> :match
      dropped_at in [:protocol, :title_guard] or language == :fell_back -> nil
      dropped_at == :language -> :mismatch
      true -> :assumed
    end
  end
end
