defmodule Cinder.Acquisition.HouseholdPolicy do
  @moduledoc """
  The household policy for one movie or series: which protocols have a download client, the
  title's audio pick, the releases blocked for it, and the size band and quality preferences the
  household set for its kind in `/settings`.

  `for_target/2` builds it the same way for the movie and TV sweeps, the upgrade sweep and the
  manual-search panel. It is the keyword list `Cinder.Acquisition.Scorer` and
  `Cinder.Acquisition.ReleaseJudge` read.

  The anime policy is not part of it: whether `Cinder.Acquisition.AnimePreferences.resolve/2`
  succeeds decides the title's anime hold, which each sweep writes itself
  (`Cinder.Catalog.set_anime_hold/2`) and the panel doesn't. So an anime caller resolves it and
  appends `anime_policy: policy` itself.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Download
  alias Cinder.LibraryKind
  alias Cinder.Settings.Registry

  @band_slots [
    :min_size,
    :max_size,
    :preferred_resolutions,
    :preferred_sources,
    :preferred_terms,
    :blocked_terms
  ]

  # Each video kind's band env keys, in `@band_slots` order, from the release-rule definitions'
  # targets: a slot with no definition fails the build.
  @band_env_keys Map.new(LibraryKind.video(), fn kind ->
                   {kind, Enum.map(@band_slots, &{&1, Registry.release_env_key!(kind, &1)})}
                 end)

  @doc """
  The household policy for `target`.

  `opts[:include_reasons]` is passed to the series blocklist
  (`Cinder.Catalog.blocked_release_titles_for_series/2`): only the upgrade sweep names
  `[:no_upgrade]`.
  """
  @spec for_target(struct(), keyword()) :: keyword()
  def for_target(target, opts \\ [])

  def for_target(%Movie{} = movie, []),
    do: common(movie, Catalog.blocked_release_titles(movie)) ++ band(:movies)

  def for_target(%Series{} = series, opts) do
    blocklist =
      Catalog.blocked_release_titles_for_series(series.id, Keyword.take(opts, [:include_reasons]))

    common(series, blocklist) ++ band(:tv)
  end

  defp common(target, blocklist) do
    [
      protocols: Download.available_protocols(),
      preferred_language: target.preferred_language,
      original_language: target.original_language,
      release_blocklist: blocklist
    ]
  end

  @doc """
  The size band and quality preferences for a library `kind` (`:movies`/`:tv`), read from the
  settings-overlaid `:cinder` env (`:movies_min_size`, `:tv_max_size`, …). Only non-nil keys are
  returned: a nil would override the scorer's own default, and an unset rule is omitted.
  """
  @spec band(:movies | :tv) :: keyword()
  def band(kind) do
    @band_env_keys
    |> Map.fetch!(kind)
    |> Enum.map(fn {slot, env_key} -> {slot, Application.get_env(:cinder, env_key)} end)
    |> Enum.reject(fn {_slot, value} -> is_nil(value) end)
  end
end
