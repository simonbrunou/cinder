defmodule Cinder.Acquisition.Scorer do
  @moduledoc """
  Selects the best release from a list by explicit, configurable rules: an
  inclusive size band, a group blocklist, and an ordered resolution preference.

  Rules come from `config :cinder, #{inspect(__MODULE__)}` merged with per-call
  `opts`. Returns `{:ok, release}` or `:no_match` when none survive the filters.
  """
  alias Cinder.Acquisition.Release

  @default_preferred ["1080p", "720p"]

  @doc """
  Picks the best release from `releases`, or `:no_match` if none survive the
  size-band and blocklist filters.
  """
  def select(releases, opts \\ []) do
    rules = Keyword.merge(config(), opts)
    min_size = Keyword.get(rules, :min_size)
    max_size = Keyword.get(rules, :max_size)
    blocklist = rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)
    preferred = Keyword.get(rules, :preferred_resolutions, @default_preferred)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> pick_best(preferred)
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp within_band?(%Release{} = release, min_size, max_size) do
    size = release.size || 0
    (is_nil(min_size) or size >= min_size) and (is_nil(max_size) or size <= max_size)
  end

  defp blocked?(%Release{group: nil}, _blocklist), do: false
  defp blocked?(%Release{group: group}, blocklist), do: String.downcase(group) in blocklist

  defp pick_best([], _preferred), do: :no_match
  defp pick_best(releases, preferred), do: {:ok, Enum.min_by(releases, &sort_key(&1, preferred))}

  defp sort_key(%Release{} = release, preferred) do
    rank = Enum.find_index(preferred, &(&1 == release.resolution)) || length(preferred)
    {rank, -(release.size || 0)}
  end
end
