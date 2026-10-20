defmodule Cinder.Acquisition.HouseholdPolicyTest do
  # Reads the settings-overlaid `:cinder` env, which the band tests below rewrite.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Acquisition.HouseholdPolicy
  alias Cinder.Catalog.BlockedRelease

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
end
