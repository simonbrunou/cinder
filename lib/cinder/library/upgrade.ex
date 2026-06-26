defmodule Cinder.Library.Upgrade do
  @moduledoc """
  Pure decision: is `new` a quality/language upgrade over `old`, per cinder's selection model
  (language-first, then resolution preference, then size)? `new`/`old` are
  `%{resolution: String.t()|nil, size: integer|nil, language: String.t()|nil}` describing a
  release/library file. Name-parsed; resolution is often nil (ranks last); size is a weak proxy.
  """
  alias Cinder.Acquisition.{Language, Scorer}

  @default_preferred ["1080p", "720p"]

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil) :: boolean()
  def better?(new, old, target, preferred) do
    lang_verdict = language_decides?(new, old, target)

    cond do
      nil_baseline?(old) -> true
      lang_verdict != :tie -> lang_verdict == :upgrade
      true -> quality_better?(new, old, preferred || @default_preferred)
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

  defp quality_better?(new, old, preferred) do
    nr = Scorer.resolution_rank(new.resolution, preferred)
    orr = Scorer.resolution_rank(old.resolution, preferred)
    nr < orr or (nr == orr and (new.size || 0) > (old.size || 0))
  end
end
