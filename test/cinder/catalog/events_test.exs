defmodule Cinder.Catalog.EventsTest do
  use Cinder.DataCase, async: true

  alias Cinder.Catalog.{Events, Movie}

  describe "the movies topic" do
    setup do
      :ok = Events.subscribe_movies()
    end

    test "carries each movie announcement" do
      movie = %Movie{id: 41, title: "Arrival"}

      assert :ok = Events.movie_created(movie)
      assert :ok = Events.movie_updated(movie)
      assert :ok = Events.movie_deleted(42)

      assert_receive {:movie_created, ^movie}
      assert_receive {:movie_updated, ^movie}
      assert_receive {:movie_deleted, 42}
    end

    test "never carries a series announcement" do
      assert :ok = Events.series_updated(7)
      assert :ok = Events.movie_deleted(42)

      assert_receive {:movie_deleted, 42}
      refute_received {:series_updated, 7}
    end
  end

  describe "the series topic" do
    setup do
      :ok = Events.subscribe_series()
    end

    test "carries each series announcement" do
      assert :ok = Events.series_updated(7)
      assert :ok = Events.series_deleted(8)
      assert :ok = Events.media_server_seasons_updated()

      assert_receive {:series_updated, 7}
      assert_receive {:series_deleted, 8}
      assert_receive :media_server_seasons_updated
    end

    test "a series with no id announces nothing" do
      assert :ok = Events.series_updated(nil)
      assert :ok = Events.series_updated(9)

      assert_receive {:series_updated, 9}
      refute_received {:series_updated, nil}
    end
  end

  test "a transition is one [:cinder, :transition] event" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:cinder, :transition]])

    assert :ok = Events.transitioned(:movie, :searching)

    assert_receive {[:cinder, :transition], ^ref, %{count: 1}, %{kind: :movie, to: :searching}}
  end
end
