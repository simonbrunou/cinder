defmodule Cinder.Library.Upgrade do
  @moduledoc """
  Pure decision: is `new` a quality/language upgrade over `old`, per cinder's selection model
  (language-first, then resolution, then source, then size)? `new`/`old` are
  `%{resolution: String.t()|nil, size: integer|nil, language: String.t()|nil, source: String.t()|nil}`
  describing a release/library file. Name-parsed; resolution/source are often nil (rank last); size
  is a weak proxy. `preferred_sources` defaults to `[]` (no source preference ⇒ source ties).
  """
  alias Cinder.Acquisition.{Language, Scorer}

  @default_preferred ["1080p", "720p"]

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil, [String.t()] | nil) ::
          boolean()
  def better?(new, old, target, preferred, preferred_sources \\ []) do
    lang_verdict = language_decides?(new, old, target)

    cond do
      nil_baseline?(old) -> true
      lang_verdict != :tie -> lang_verdict == :upgrade
      true -> quality_better?(new, old, preferred || @default_preferred, preferred_sources || [])
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
    # ponytail: Map.get guards callers that pre-date the :source key; later tasks add :source to
    # every quality map — at that point this is equivalent to q.source.
    {Scorer.resolution_rank(q.resolution, preferred),
     Scorer.source_rank(Map.get(q, :source), sources), -(q.size || 0)}
  end
end
