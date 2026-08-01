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

  `covers` is how many episodes the release carries (1 for a movie or a single episode). The
  release's size is divided by it, because `record`'s `imported_size` is **one file** while a
  season pack's size is the whole pack: compared raw, size is `better?/5`'s last tiebreak and
  larger wins, so *every* same-resolution pack would read as an upgrade, download, be declined
  per-file at import, and be re-downloaded on every sweep forever. Same scaling convention as
  `Cinder.Acquisition.Scorer`'s `scale_band/2`.

  Name-parsed and therefore advisory: a `%Release{}` carries what the indexer's title implied, not
  what the file turns out to be. The **import stays the arbiter** — it re-runs `better?/5` against
  the real file and keeps the existing one if the promise didn't hold — so a mis-parsed name can
  never replace a good file with a worse one.
  """
  def candidate?(record, %Release{} = release, kind, target, covers \\ 1)
      when is_integer(covers) and covers > 0 do
    better?(
      %{
        resolution: release.resolution,
        source: release.source,
        size: per_episode(release.size, covers),
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
      preferred_sources(kind)
    )
  end

  defp per_episode(nil, _covers), do: nil
  defp per_episode(size, covers), do: div(size, covers)

  @doc "The household's preferred resolutions for library `kind`, best first (`nil` when unset)."
  def preferred_resolutions(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_resolutions")

  @doc "The household's preferred sources for library `kind`, best first (`nil` when unset)."
  def preferred_sources(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_sources")

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil, [String.t()] | nil) ::
          boolean()
  def better?(new, old, target, preferred, preferred_sources \\ []) do
    lang_verdict = language_decides?(new, old, target)

    cond do
      nil_baseline?(old) ->
        true

      lang_verdict != :tie ->
        lang_verdict == :upgrade

      true ->
        quality_better?(
          new,
          old,
          preferred || Scorer.default_preferred(),
          preferred_sources || []
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
  defp quality_better?(new, old, preferred, sources) do
    rank(new, preferred, sources) < rank(old, preferred, sources)
  end

  defp rank(q, preferred, sources) do
    {Scorer.resolution_rank(q.resolution, preferred), Scorer.source_rank(q.source, sources),
     -(q.size || 0)}
  end
end
