defmodule Cinder.Acquisition.HouseholdPolicyTest do
  # Reads the settings-overlaid `:cinder` env, which the band tests below rewrite.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Acquisition.HouseholdPolicy
  alias Cinder.Catalog.BlockedRelease
  alias Cinder.ConfigCase
  alias Cinder.LibraryKind
  alias Cinder.Settings.Registry

  @band_keys [:movies_max_size, :movies_preferred_resolutions, :tv_min_size, :tv_blocked_terms]

  setup do
    saved = Map.new(@band_keys, &{&1, Application.fetch_env(:cinder, &1)})

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:cinder, key, value)
          :error -> Application.delete_env(:cinder, key)
        end
      end
    end)
  end

  test "a movie's policy carries its clients, audio pick, blocklist and the movie band" do
    Application.put_env(:cinder, :movies_max_size, 20_000_000_000)
    Application.put_env(:cinder, :movies_preferred_resolutions, ["2160p"])
    Application.put_env(:cinder, :tv_min_size, 1)

    movie = movie_fixture(%{preferred_language: "french", original_language: "en"})
    Repo.insert!(%BlockedRelease{release_title: "Bad.Release", reason: "x", movie_id: movie.id})

    policy = HouseholdPolicy.for_target(movie)

    assert Enum.sort(policy[:protocols]) == [:torrent, :usenet]
    assert policy[:preferred_language] == "french"
    assert policy[:original_language] == "en"
    assert policy[:release_blocklist] == ["Bad.Release"]
    assert policy[:max_size] == 20_000_000_000
    assert policy[:preferred_resolutions] == ["2160p"]
    refute Keyword.has_key?(policy, :min_size)
  end

  # An unset rule is omitted rather than passed as nil: a nil would override the scorer's own
  # default (the resolution allow-list falls back to 1080p/720p only when the key is absent).
  test "a series' policy carries the TV band and leaves unset rules out" do
    Application.put_env(:cinder, :tv_min_size, 1_000)
    Application.put_env(:cinder, :tv_blocked_terms, ["cam"])
    Application.delete_env(:cinder, :movies_max_size)

    policy = HouseholdPolicy.for_target(series_fixture(%{preferred_language: "original"}))

    assert policy[:min_size] == 1_000
    assert policy[:blocked_terms] == ["cam"]
    refute Keyword.has_key?(policy, :max_size)
    assert policy[:preferred_language] == "original"
  end

  # The env key comes from each definition's target, never from a template, so a renamed slot or
  # key fails here instead of leaving band/1 reading a key nothing writes.
  test "band/1 reads every rule from its definition's env target, in order, for each video kind" do
    for {kind, n} <- Enum.with_index(LibraryKind.video(), 1) do
      expected = [
        min_size: 10 * n + 1,
        max_size: 10 * n + 2,
        preferred_resolutions: ["#{kind}-res"],
        preferred_sources: ["#{kind}-src"],
        preferred_terms: ["#{kind}-term"],
        blocked_terms: ["#{kind}-blocked"]
      ]

      for {slot, value} <- expected do
        %{target: {:env, env_key}} = Registry.one!(group: :releases, kind: kind, slot: slot)
        ConfigCase.put_env(env_key, value)
      end

      assert HouseholdPolicy.band(kind) == expected
    end
  end

  # A season pack the import arbitrated down to nothing placed is blocked for the upgrade sweep
  # only (#274); the wanted-episode sweep and the panel still see it.
  test "a series blocklist leaves out upgrade-only reasons unless the caller names them" do
    series = series_fixture()

    Repo.insert!(%BlockedRelease{release_title: "Bad.Pack", reason: "x", series_id: series.id})

    Repo.insert!(%BlockedRelease{
      release_title: "Best.Pack",
      reason: "no_upgrade",
      series_id: series.id
    })

    assert HouseholdPolicy.for_target(series)[:release_blocklist] == ["Bad.Pack"]

    assert series
           |> HouseholdPolicy.for_target(include_reasons: [:no_upgrade])
           |> Keyword.fetch!(:release_blocklist)
           |> Enum.sort() == ["Bad.Pack", "Best.Pack"]
  end

  # #1515: a refused TV submission's row carries its indexer id into every caller's blocklist,
  # the upgrade sweep's included.
  test "a series blocklist gives a row with an indexer id as {title, indexer_id}" do
    series = series_fixture()

    Repo.insert!(%BlockedRelease{
      release_title: "Refused.Pack",
      reason: "bad_torrent",
      indexer_id: 7,
      series_id: series.id
    })

    Repo.insert!(%BlockedRelease{release_title: "Bad.Pack", reason: "x", series_id: series.id})

    for opts <- [[], [include_reasons: [:no_upgrade]]] do
      assert series
             |> HouseholdPolicy.for_target(opts)
             |> Keyword.fetch!(:release_blocklist)
             |> Enum.sort() == [{"Refused.Pack", 7}, "Bad.Pack"]
    end
  end
end
