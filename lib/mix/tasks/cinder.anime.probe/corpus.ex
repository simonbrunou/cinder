defmodule Mix.Tasks.Cinder.Anime.Probe.Corpus do
  @moduledoc false

  @kinds ["tv", "movie"]
  @expect_keys ~w(min_discovery_hits required_group_types min_absolute_entries require_specials)
  @behavior_kinds ~w(release resolver preflight snapshot)
  @behavior_phases ~w(A1 A2 A3)
  @behavior_keys ~w(id phase kind input expect)
  @required_behavior_ids ~w(
    ordinary-cour-sxxeyy absolute-over-99 absolute-over-999-v2-crc
    split-cour-absolute-range cross-season-batch dual-audio-dub-ass-markers
    ova-typed-special ona-not-automatically-special recap-is-story-candidate episode-zero
    ncop-extra nced-extra trailer-extra ambiguous-bare-number anime-movie-release coordinate-to-many
    coordinates-to-one unknown-video-needs-mapping duplicate-target-needs-mapping
    outside-reservation-needs-mapping explicit-extra-can-ignore sidecar-does-not-count-as-video
    ambiguous-coordinate-needs-mapping provider-renumbering-preserves-active-work
  )

  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> normalize!()
  rescue
    error in [Jason.DecodeError, KeyError, ArgumentError] ->
      reraise ArgumentError.exception("invalid anime corpus: #{Exception.message(error)}"),
              __STACKTRACE__
  end

  defp normalize!(%{
         "version" => 1,
         "titles" => titles,
         "behavior_contracts" => behavior_contracts
       })
       when is_list(titles) and titles != [] and is_list(behavior_contracts) do
    normalized = Enum.map(titles, &title!/1)
    slugs = Enum.map(normalized, & &1.slug)
    if Enum.uniq(slugs) != slugs, do: raise(ArgumentError, "duplicate slug")

    behaviors = Enum.map(behavior_contracts, &behavior!/1)
    ids = Enum.map(behaviors, & &1.id)

    unless Enum.sort(ids) == Enum.sort(@required_behavior_ids),
      do: raise(ArgumentError, "missing, duplicate, or unknown behavior contract")

    %{version: 1, titles: normalized, behavior_contracts: behaviors}
  end

  defp normalize!(_),
    do: raise(ArgumentError, "expected v1 titles and behavior contracts")

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp title!(%{
         "slug" => slug,
         "kind" => kind,
         "tmdb_id" => tmdb_id,
         "discovery_queries" => discovery,
         "prowlarr_queries" => prowlarr,
         "expect" => expect
       })
       when is_binary(slug) and kind in @kinds and is_integer(tmdb_id) and tmdb_id > 0 and
              is_list(discovery) and discovery != [] and is_list(prowlarr) and prowlarr != [] and
              is_map(expect) do
    unless Enum.all?(discovery ++ prowlarr, &(is_binary(&1) and &1 != "")),
      do: raise(ArgumentError, "blank query for #{slug}")

    unless Enum.sort(Map.keys(expect)) == Enum.sort(@expect_keys),
      do: raise(ArgumentError, "invalid expectations for #{slug}")

    min_discovery_hits = positive_integer!(expect["min_discovery_hits"])

    if min_discovery_hits > length(discovery),
      do: raise(ArgumentError, "min_discovery_hits exceeds queries for #{slug}")

    %{
      slug: slug,
      kind: kind_atom(kind),
      tmdb_id: tmdb_id,
      discovery_queries: discovery,
      prowlarr_queries: prowlarr,
      expect: %{
        min_discovery_hits: min_discovery_hits,
        required_group_types: integer_list!(expect["required_group_types"]),
        min_absolute_entries: non_negative_integer!(expect["min_absolute_entries"]),
        require_specials: boolean!(expect["require_specials"])
      }
    }
  end

  defp title!(_), do: raise(ArgumentError, "incomplete title")

  defp behavior!(
         %{
           "id" => id,
           "phase" => phase,
           "kind" => kind,
           "input" => input,
           "expect" => expect
         } = behavior
       )
       when is_binary(id) and phase in @behavior_phases and kind in @behavior_kinds and
              is_map(input) and map_size(input) > 0 and is_map(expect) and map_size(expect) > 0 do
    unless Enum.sort(Map.keys(behavior)) == Enum.sort(@behavior_keys),
      do: raise(ArgumentError, "invalid behavior contract #{id}")

    %{id: id, phase: phase, kind: kind, input: input, expect: expect}
  end

  defp behavior!(_), do: raise(ArgumentError, "incomplete behavior contract")

  defp kind_atom("tv"), do: :tv
  defp kind_atom("movie"), do: :movie
  defp positive_integer!(n) when is_integer(n) and n > 0, do: n
  defp positive_integer!(_), do: raise(ArgumentError, "expected positive integer")
  defp non_negative_integer!(n) when is_integer(n) and n >= 0, do: n
  defp non_negative_integer!(_), do: raise(ArgumentError, "expected non-negative integer")

  defp integer_list!(list) when is_list(list) do
    if Enum.all?(list, &is_integer/1),
      do: list,
      else: raise(ArgumentError, "expected integer list")
  end

  defp integer_list!(_), do: raise(ArgumentError, "expected integer list")
  defp boolean!(value) when is_boolean(value), do: value
  defp boolean!(_), do: raise(ArgumentError, "expected boolean")
end
