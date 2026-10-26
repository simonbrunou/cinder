defmodule Cinder.Catalog.MediaServerSeasonsTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.MediaServerSeasons

  # A normalized TMDB series (`Cinder.Catalog.TMDB` `get_series/1`) listing specials, seasons of
  # 10, 10 and 8 episodes, and a season 4 with no count. `last` and `next` are the
  # `{season, episode}` of its last and next episodes to air, or nil.
  defp series(last, next) do
    %{
      seasons: [
        %{season_number: 0, episode_count: 3},
        %{season_number: 1, episode_count: 10},
        %{season_number: 2, episode_count: 10},
        %{season_number: 3, episode_count: 8},
        %{season_number: 4, episode_count: nil}
      ],
      last_episode_to_air: episode(last),
      next_episode_to_air: episode(next)
    }
  end

  defp episode(nil), do: nil
  defp episode({season, number}), do: %{season_number: season, episode_number: number}

  describe "aired_total/2" do
    test "a season mid-air counts the episodes aired so far" do
      assert MediaServerSeasons.aired_total(series({2, 8}, {2, 9}), 2) == {:airing, 8}
    end

    test "every other season counts TMDB's episode_count" do
      mid_air = series({2, 8}, {2, 9})

      assert MediaServerSeasons.aired_total(mid_air, 1) == {:listed, 10}
      assert MediaServerSeasons.aired_total(mid_air, 3) == {:listed, 8}
      assert MediaServerSeasons.aired_total(mid_air, 4) == {:listed, nil}
    end

    test "a season whose premiere has not aired counts its episode_count" do
      premiere_next = series({1, 10}, {2, 1})

      assert MediaServerSeasons.aired_total(premiere_next, 2) == {:listed, 10}
      assert MediaServerSeasons.aired_total(premiere_next, 1) == {:listed, 10}
    end

    test "a special that aired last does not make the next season mid-air" do
      assert MediaServerSeasons.aired_total(series({0, 3}, {2, 9}), 2) == {:listed, 10}
    end

    test "a last aired episode numbered 0 does not make the season mid-air" do
      assert MediaServerSeasons.aired_total(series({2, 0}, {2, 1}), 2) == {:listed, 10}
    end

    test "with no episode scheduled, every season counts its episode_count" do
      assert MediaServerSeasons.aired_total(series({2, 8}, nil), 2) == {:listed, 10}
      assert MediaServerSeasons.aired_total(series(nil, nil), 1) == {:listed, 10}
    end

    test "a series without the airing fields counts every season's episode_count" do
      assert MediaServerSeasons.aired_total(
               %{seasons: [%{season_number: 1, episode_count: 6}]},
               1
             ) ==
               {:listed, 6}
    end

    test "a season TMDB does not list counts nil" do
      assert MediaServerSeasons.aired_total(series({2, 8}, {2, 9}), 7) == {:listed, nil}
    end
  end

  describe "coverage/3" do
    test "an airing season the server holds up to its aired total is up to date, not complete" do
      mid_air = series({2, 8}, {2, 9})

      assert MediaServerSeasons.coverage(mid_air, 2, 8) == :up_to_date
      assert MediaServerSeasons.coverage(mid_air, 2, 10) == :up_to_date
      assert MediaServerSeasons.coverage(mid_air, 2, 7) == {:incomplete, 8}
    end

    test "a finished season is complete only at TMDB's episode_count" do
      mid_air = series({2, 8}, {2, 9})

      assert MediaServerSeasons.coverage(mid_air, 1, 10) == :complete
      assert MediaServerSeasons.coverage(mid_air, 1, 8) == {:incomplete, 10}
    end

    test "a season with no episode_count is never complete" do
      assert MediaServerSeasons.coverage(series({2, 8}, {2, 9}), 4, 12) == {:incomplete, nil}

      assert MediaServerSeasons.coverage(
               %{seasons: [%{season_number: 1, episode_count: 0}]},
               1,
               0
             ) ==
               {:incomplete, 0}
    end

    test "a season whose premiere has not aired keeps the episode_count rule" do
      premiere_next = series({1, 10}, {2, 1})

      assert MediaServerSeasons.coverage(premiere_next, 2, 3) == {:incomplete, 10}
      assert MediaServerSeasons.coverage(premiere_next, 2, 10) == :complete
    end

    # Read as airing, an episode 0 would make an empty server count up to date.
    test "an empty server count of a season whose last aired episode is 0 is incomplete" do
      assert MediaServerSeasons.coverage(series({2, 0}, {2, 1}), 2, 0) == {:incomplete, 10}
    end
  end
end
