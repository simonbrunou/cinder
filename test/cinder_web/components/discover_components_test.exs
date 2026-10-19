defmodule CinderWeb.DiscoverComponentsTest do
  use ExUnit.Case, async: true

  import CinderWeb.DiscoverComponents, only: [title_state: 3]

  alias Cinder.Requests.Target

  describe "title_state/3" do
    # `RequestHelpers.assign_request_state/1` keys the user's requests by `Target.key/1`, so a
    # book or season request that shares the movie card's number sits under its own key.
    test "reads only the movie's own request" do
      tmdb_id = 42

      others = %{
        Target.key(%{target_type: "book", target_id: tmdb_id, media_kind: :ebook}) => :pending,
        Target.key(%{target_type: "season", target_id: tmdb_id, season_number: 1}) => :denied
      }

      assert title_state(tmdb_id, others, %{}) == :none

      mine = Map.put(others, Target.key(%{target_type: "movie", target_id: tmdb_id}), :approved)
      assert title_state(tmdb_id, mine, %{}) == :approved
    end

    test "a watchable movie outranks the request, an upgrade included" do
      request_status = %{{:movie, 7} => :denied}

      assert title_state(7, request_status, %{7 => :available}) == :available
      assert title_state(7, request_status, %{7 => :upgrading}) == :available
      assert title_state(7, request_status, %{7 => :import_failed}) == :denied
    end
  end
end
