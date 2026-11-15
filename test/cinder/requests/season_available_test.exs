defmodule Cinder.Requests.SeasonAvailableTest do
  # A season the media server holds in full is refused at filing (#720).
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{MediaServerSeason, Season}
  alias Cinder.Requests
  alias Cinder.Requests.Request

  setup :verify_on_exit!

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n, _locale ->
      {:ok,
       %{
         season_number: n,
         episodes: [
           %{tmdb_episode_id: n * 10 + 1, episode_number: 1, title: "e", air_date: ~D[2011-01-01]}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 1399 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 1399 -> {:ok, []} end)
    :ok
  end

  defp stub_series(extra \\ %{}) do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok,
       Map.merge(
         %{
           tmdb_id: 1399,
           tvdb_id: 1,
           title: "GoT",
           year: 2011,
           poster_path: nil,
           seasons: [
             %{season_number: 1, episode_count: 10},
             %{season_number: 2, episode_count: 8}
           ]
         },
         extra
       )}
    end)
  end

  defp on_server(season_number, count) do
    Repo.insert!(%MediaServerSeason{
      tmdb_id: 1399,
      season_number: season_number,
      episode_count: count,
      item_id: "plex:42"
    })
  end

  defp season(number), do: %{target_type: "season", target_id: 1399, season_number: number}

  test "a season the server holds in full is refused and files no request, for an admin too" do
    stub_series()
    on_server(1, 10)

    assert {:error, :season_available} = Requests.create_request(user_fixture(), season(1))
    assert {:error, :season_available} = Requests.create_request(admin_fixture(), season(1))
    assert Repo.aggregate(Request, :count) == 0
    assert Catalog.get_series_by_tmdb_id(1399) == nil
  end

  test "a season the server holds only part of is accepted" do
    stub_series()
    on_server(1, 4)

    assert {:ok, %Request{status: :pending}} = Requests.create_request(user_fixture(), season(1))
  end

  test "another season of a show the server holds is accepted" do
    stub_series()
    on_server(1, 10)

    assert {:ok, %Request{status: :pending}} = Requests.create_request(user_fixture(), season(2))
  end

  test "an airing season holding every aired episode is accepted, so its next episodes come" do
    # Six of eight aired; the server holds all six, and even a count at episode_count reads as up
    # to date while the season airs.
    stub_series(%{
      last_episode_to_air: %{season_number: 2, episode_number: 6},
      next_episode_to_air: %{season_number: 2, episode_number: 7}
    })

    on_server(2, 8)

    assert {:ok, %Request{status: :pending}} = Requests.create_request(user_fixture(), season(2))
  end

  test "with no TMDB answer the request goes through: nothing to judge the count against" do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 -> {:error, :timeout} end)
    on_server(1, 10)

    assert {:ok, %Request{status: :pending}} = Requests.create_request(user_fixture(), season(1))
  end

  test "approving a season arms the library check and reads no file" do
    stub_series()
    # FilesystemMock has no stub: an approval that read the library would raise here.
    assert {:ok, %Request{status: :approved}} =
             Requests.create_request(admin_fixture(), season(2))

    tree = Catalog.get_series_with_tree(Catalog.get_series_by_tmdb_id(1399).id)
    assert %Season{library_check_armed_at: %DateTime{}} = season_numbered(tree, 2)
    assert %Season{library_check_armed_at: nil} = season_numbered(tree, 1)
  end

  defp season_numbered(tree, n), do: Enum.find(tree.seasons, &(&1.season_number == n))
end
