defmodule Cinder.Library.Upgrade do
  @moduledoc """
  Pure decision: is `new` a quality/language upgrade over `old`, per cinder's selection model
  (language-first, then resolution, then source, then size)? `new`/`old` are
  `%{resolution: String.t()|nil, size: integer|nil, language: String.t()|nil, source: String.t()|nil}`
  describing a release/library file. Name-parsed; resolution/source are often nil (rank last); size
  is a weak proxy. `preferred_sources` defaults to `[]` (no source preference ⇒ source ties).
  """
  alias Cinder.Acquisition.{Language, Release, Scorer}

  @doc """
  Whether `release` *promises* a better file than `record` (a `Movie` or an `Episode`) already
  holds, for library `kind` (`:movies` / `:tv`) with language `target` — `better?/5` over the two
  sides a caller would otherwise have to assemble itself. `Cinder.Catalog.UpgradeHunter` asks this
  *before* downloading, so a sideways or worse release costs nothing.

  Language, resolution and source decide here; **size does not**. `release.size` is the indexer's
  total for the whole container — nfo, sample, a subs folder, and for a pack every episode — while
  `record`'s `imported_size` is the one video file `lstat`ed out of it. Compared at all, a
  multi-file release therefore out-ranks the very file it produced, at identical quality, forever:
  the sweep re-grabs it, re-downloads it, replaces the file with an identical one and repeats
  (#278). The two numbers measure different things and no scaling makes them commensurable, so the
  pre-download gate simply doesn't ask. Cost: a same-resolution/same-source size upgrade (a bigger
  remux) is not found by the sweep — it stays reachable through manual search, where the operator
  chooses and the import is forced.

  Name-parsed and therefore advisory: a `%Release{}` carries what the indexer's title implied, not
  what the file turns out to be. The **import stays the arbiter** — it re-runs `better?/5` against
  the real file, where both sides are `lstat` results and size legitimately decides — so a
  mis-parsed name can never replace a good file with a worse one.

  Every caller of this function (`UpgradeHunter`) already restricts `record` to a row that has a
  file (`file_path`/`imported_*` describe a real, held file — see `hunt_movies/0`/`holdings/0`).
  So unlike `better?/5`, a fully nil baseline here is never "nothing held yet"; it is an
  established file whose quality was simply never recorded — adopted from disk/Radarr/Sonarr, or
  imported before the quality columns existed. #520: treating that as an unconditional win let any
  acceptable release replace a superior adopted file the first time the sweep looked at it. This
  fails closed instead: no baseline, no automatic candidate. A manual/forced import (which always
  records real quality) establishes one, after which normal comparison applies.
  """
  def candidate?(record, %Release{} = release, kind, target) do
    compare(
      %{
        resolution: release.resolution,
        source: release.source,
        size: release.size,
        language: release.language
      },
      %{
        resolution: record.imported_resolution,
        source: record.imported_source,
        size: record.imported_size,
        language: record.imported_language
      },
      target,
      preferred_resolutions(kind),
      preferred_sources(kind),
      false,
      false
    )
  end

  @doc "The household's preferred resolutions for library `kind`, best first (`nil` when unset)."
  def preferred_resolutions(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_resolutions")

  @doc "The household's preferred sources for library `kind`, best first (`nil` when unset)."
  def preferred_sources(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_sources")

  @doc "Whether a library record has reached the configured automatic-upgrade cutoff."
  def cutoff_met?(record, kind) do
    preferred = preferred_resolutions(kind) || Scorer.default_preferred()
    cutoff = Application.get_env(:cinder, :"#{kind}_upgrade_cutoff")

    case Enum.find_index(preferred, &(&1 == cutoff)) do
      nil -> false
      cutoff_rank -> Scorer.resolution_rank(record.imported_resolution, preferred) <= cutoff_rank
    end
  end

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil, [String.t()] | nil) ::
          boolean()
  def better?(new, old, target, preferred, preferred_sources \\ []),
    do: compare(new, old, target, preferred, preferred_sources, true, true)

  # `weigh_size?` is false only for `candidate?/4` — see its doc for why a release's size and an
  # imported file's size are not the same quantity. `nil_baseline_wins?` is true only for
  # `better?/5` (an import comparing against a genuinely absent old file is a legitimate,
  # unconditional win); `candidate?/4`'s pre-download gate fails closed instead (#520).
  defp compare(new, old, target, preferred, preferred_sources, weigh_size?, nil_baseline_wins?) do
    lang_verdict = language_decides?(new, old, target)

    cond do
      nil_baseline?(old) ->
        nil_baseline_wins?

      lang_verdict != :tie ->
        lang_verdict == :upgrade

      true ->
        quality_better?(
          new,
          old,
          preferred || Scorer.default_preferred(),
          preferred_sources || [],
          weigh_size?
        )
    end
  end

  defp nil_baseline?(%{resolution: nil, size: nil, language: nil}), do: true
  defp nil_baseline?(_), do: false

  defp language_decides?(new, old, target) do
    cond do
      is_nil(target) ->
        :tie

      not Language.satisfies_lang?(old.language, target) and
          Language.satisfies_lang?(new.language, target) ->
        :upgrade

      Language.satisfies_lang?(old.language, target) and
          not Language.satisfies_lang?(new.language, target) ->
        :downgrade

      true ->
        :tie
    end
  end

  # Lexicographic over {resolution rank, source rank, -size}: lower is better — better resolution,
  # then more-preferred source, then larger size. Mirrors Scorer.sort_key. With preferred_sources []
  # the source rank ties at 0 for all, so this reduces to the prior resolution-then-size decision.
  defp quality_better?(new, old, preferred, sources, weigh_size?) do
    rank(new, preferred, sources, weigh_size?) < rank(old, preferred, sources, weigh_size?)
  end

  defp rank(q, preferred, sources, weigh_size?) do
    {Scorer.resolution_rank(q.resolution, preferred), Scorer.source_rank(q.source, sources),
     if(weigh_size?, do: -(q.size || 0), else: 0)}
  end
end
