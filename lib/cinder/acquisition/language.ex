defmodule Cinder.Acquisition.Language do
  @moduledoc """
  Per-item preferred-language filtering for release selection.

  A user picks `"original"` / `"french"` / `"any"` per movie/series. This resolves
  the pick to a concrete target language code — using the title's TMDB
  `original_language` for `"original"` — then keeps only releases whose parsed
  `language` satisfies it: a `MULTI` release, an exact-tag match, or, for the
  title's original language, an untagged (`nil`) release (untagged = original
  audio). `"any"` / an unknown original disables the filter. Filter-only: the
  scorer's ranking is untouched.
  """
  alias Cinder.Acquisition.Release

  @tags %{"fr" => "FRENCH", "de" => "GERMAN", "es" => "SPANISH", "it" => "ITALIAN"}

  @doc """
  Keeps only releases satisfying the resolved target. Returns the list unchanged
  when the filter is inactive (`"any"`, or `"original"` with a blank/nil original).
  """
  def filter(releases, preferred, original) do
    case target(preferred, original) do
      nil -> releases
      t -> Enum.filter(releases, &satisfies?(&1, t, original))
    end
  end

  @doc "Whether a language filter is active for this preference + original language."
  def active?(preferred, original), do: not is_nil(target(preferred, original))

  @doc """
  Whether an unsatisfiable preference parks the item (an explicit language pick) rather
  than falling back to the unfiltered candidates (the soft Original/Any default).
  """
  def strict?(preferred) when preferred in ["original", "any", nil], do: false
  def strict?(_explicit), do: true

  @doc "Resolves a preference + the title's original language to a target code, or nil (filter off)."
  def target("french", _original), do: "fr"
  def target("original", original), do: presence(original)
  def target(_other, _original), do: nil

  @doc "Whether a single release satisfies the target language for a title with original language `original`."
  def satisfies?(%Release{language: "MULTI"}, _target, _original), do: true
  def satisfies?(%Release{language: nil}, target, original), do: target == presence(original)
  def satisfies?(%Release{language: language}, target, _original), do: language == tag(target)

  defp tag(code), do: Map.get(@tags, code)

  defp presence(code) when code in [nil, ""], do: nil
  defp presence(code), do: code
end
