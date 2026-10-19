defmodule Cinder.Requests.TargetTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Books
  alias Cinder.Requests.Target

  # One integer that is at once a book work id, a movie TMDB id and a series TMDB id. A work id is
  # an autoincrement, so the work comes first and the catalog rows borrow its id.
  defp colliding_id(world) do
    {:ok, work} =
      Books.upsert_work(%{
        title: "Colliding Work",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: inspect(world)}
      })

    work.id
  end

  describe "resolve/1 across one colliding id" do
    # Every target type shares one integer id. The two worlds set the targets to opposite states,
    # so reading any of them through another type's id space gives a wrong field in one world.
    @worlds [
      %{movie: :available, season: :landed, book: :monitored},
      %{movie: :downloading, season: :missing_episode, book: :available}
    ]

    test "each target type answers from its own id space" do
      for world <- @worlds do
        id = colliding_id(world)
        movie_fixture(tmdb_id: id, title: "Colliding Movie", status: world.movie)

        Repo.update_all(where(Cinder.Catalog.Movie, tmdb_id: ^id),
          set: [media_server_item_id: "m"]
        )

        series = series_fixture(tmdb_id: id, title: "Colliding Show", media_server_item_id: "s")
        season = season_fixture(series, season_number: 1)
        episode_fixture(season, episode_number: 1, file_path: "/lib/show/s01e01.mkv")

        if world.season == :missing_episode,
          do: episode_fixture(season, episode_number: 2, file_path: nil)

        {:ok, target} = Books.ensure_target(Repo.get!(Books.Work, id), :ebook)
        Repo.update!(Ecto.Changeset.change(target, status: world.book))

        refs = [
          %{target_type: "movie", target_id: id},
          season_ref(id, 1),
          book_ref(id, :ebook),
          book_ref(id, :audiobook),
          %{target_type: "series", target_id: id},
          %{target_type: "episode", target_id: id, season_number: 1}
        ]

        resolved = Target.resolve(refs)
        assert Enum.map(resolved, &elem(&1, 0)) == refs

        assert Enum.map(resolved, fn {_ref, t} -> summary(t) end) == expected(world, id)
      end
    end
  end

  # The fields a caller reads, with the loaded movie reduced to its status.
  defp summary(t) do
    {t.key, t.watchable?, t.outstanding?, t.title, t.media_server_item_id,
     t.movie && t.movie.status, t.season_progress && t.season_progress.available, t.book_status}
  end

  defp expected(world, id) do
    movie_landed? = world.movie == :available
    season_landed? = world.season == :landed

    [
      {{:movie, id}, movie_landed?, not movie_landed?, "Colliding Movie", "m", world.movie, nil,
       nil},
      {{:season, id, 1}, season_landed?, not season_landed?, "Colliding Show", "s", nil, 1, nil},
      {{:book, id, :ebook}, false, world.book != :available, nil, nil, nil, nil, world.book},
      {{:book, id, :audiobook}, false, true, nil, nil, nil, nil, nil},
      {{:unsupported, "series", id}, false, true, nil, nil, nil, nil, nil},
      {{:unsupported, "episode", id}, false, true, nil, nil, nil, nil, nil}
    ]
  end

  describe "key/1" do
    test "gives a malformed ref an unsupported key rather than a guessed one" do
      assert Target.key(%{target_type: "season", target_id: 5, season_number: nil}) ==
               {:unsupported, "season", 5}

      assert Target.key(%{target_type: "book", target_id: 5, media_kind: nil}) ==
               {:unsupported, "book", 5}

      assert Target.key(%{target_type: "movie", target_id: "5"}) == {:unsupported, "movie", "5"}
    end

    test "reads an issue report, which carries no media kind" do
      report = %Cinder.Issues.IssueReport{target_type: "season", target_id: 5, season_number: 2}
      assert Target.key(report) == {:season, 5, 2}
    end
  end

  describe "a movie target" do
    # {state, watchable?, outstanding?}. Watchable means the library file plays now; outstanding
    # means an approved request on it still holds a quota slot. An upgrade keeps the old file, and
    # an operator's cancel settles the request, so neither holds a slot.
    @movie_cells [
      {:requested, false, true},
      {:downloading, false, true},
      {:no_match, false, true},
      {:import_failed, false, true},
      {:available, true, false},
      {:upgrading, true, false},
      {:cancelled, false, false},
      {{:import_failed, :download}, false, true},
      {{:import_failed, :upgrade}, false, false}
    ]

    test "answers watchable? and outstanding? per state" do
      for {state, watchable?, outstanding?} <- @movie_cells do
        movie = movie_in(state)
        [{_ref, t}] = Target.resolve([%{target_type: "movie", target_id: movie.tmdb_id}])

        assert {state, t.watchable?, t.outstanding?} == {state, watchable?, outstanding?}
      end
    end

    test "a movie with no row is outstanding and not watchable" do
      [{_ref, t}] = Target.resolve([%{target_type: "movie", target_id: 404_404}])

      assert {t.movie, t.watchable?, t.outstanding?} == {nil, false, true}
    end
  end

  describe "a season target" do
    # {season row, watchable?, outstanding?}. A season is watchable once every aired episode has
    # its file. Unmonitoring a season (cancel_series/2 does it to the whole tree) settles it.
    @season_cells [
      {{:monitored, :landed}, true, false},
      {{:monitored, :missing_episode}, false, true},
      {{:unmonitored, :landed}, true, false},
      {{:unmonitored, :missing_episode}, false, false}
    ]

    test "answers watchable? and outstanding? per state" do
      for {{monitored, episodes} = state, watchable?, outstanding?} <- @season_cells do
        series = series_fixture(media_server_item_id: "plex:machine:1")
        season = season_fixture(series, season_number: 2, monitored: monitored == :monitored)
        episode_fixture(season, episode_number: 1, file_path: "/lib/show/s02e01.mkv")

        if episodes == :missing_episode,
          do: episode_fixture(season, episode_number: 2, file_path: nil)

        [{_ref, t}] = Target.resolve([season_ref(series.tmdb_id, 2)])

        assert {state, t.watchable?, t.outstanding?} == {state, watchable?, outstanding?}
        assert t.media_server_item_id == "plex:machine:1"
      end
    end

    test "carries episode progress while the season fills" do
      series = series_fixture()
      season = season_fixture(series, season_number: 1)
      episode_fixture(season, episode_number: 1, file_path: "/lib/show/s01e01.mkv")
      grabbed = episode_fixture(season, episode_number: 2)
      episode_fixture(season, episode_number: 3)
      {:ok, _grab} = Cinder.Catalog.create_grab("season-progress", :torrent, [grabbed.id])

      [{_ref, t}] = Target.resolve([season_ref(series.tmdb_id, 1)])

      assert t.season_progress == %{total: 3, available: 1, downloading: true}
    end

    # Kept as it was before the resolver existed: the quota only counts a season row it can see
    # as monitored, so a request whose season row is gone (or never existed) holds no slot.
    test "a season with no row is neither watchable nor outstanding, but keeps the series title" do
      series = series_fixture(title: "Rowless")

      [{_ref, t}] = Target.resolve([season_ref(series.tmdb_id, 7)])

      assert {t.title, t.watchable?, t.outstanding?, t.season_progress} ==
               {"Rowless", false, false, nil}
    end
  end

  describe "a book target" do
    # {target status, outstanding?}. A book lands in Booklore or Audiobookshelf, never on the media
    # server, so it is never watchable. Pausing a target (`:unmonitored`) settles the request.
    @book_cells [
      {:monitored, true},
      {:held, true},
      {:available, false},
      {:unmonitored, false}
    ]

    test "answers outstanding? per state and is never watchable" do
      for {status, outstanding?} <- @book_cells do
        work = work_fixture()
        {:ok, target} = Books.ensure_target(work, :audiobook)
        hold_reason = if status == :held, do: "test_reason"
        Repo.update!(Ecto.Changeset.change(target, status: status, hold_reason: hold_reason))

        [{_ref, t}] = Target.resolve([book_ref(work.id, :audiobook)])

        assert {status, t.book_status, t.watchable?, t.outstanding?} ==
                 {status, status, false, outstanding?}
      end
    end

    test "each media kind of one work resolves to its own target" do
      work = work_fixture()
      {:ok, ebook} = Books.ensure_target(work, :ebook)
      Repo.update!(Ecto.Changeset.change(ebook, status: :available))

      assert [{_, ebook_t}, {_, audiobook_t}] =
               Target.resolve([book_ref(work.id, :ebook), book_ref(work.id, :audiobook)])

      assert {ebook_t.book_status, ebook_t.outstanding?} == {:available, false}
      assert {audiobook_t.book_status, audiobook_t.outstanding?} == {nil, true}
    end
  end

  defp work_fixture do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    work
  end

  defp book_ref(work_id, kind), do: %{target_type: "book", target_id: work_id, media_kind: kind}

  defp season_ref(tmdb_id, n), do: %{target_type: "season", target_id: tmdb_id, season_number: n}

  defp movie_in({status, hold_origin}) do
    movie = movie_in(status)

    Repo.update_all(from(m in Cinder.Catalog.Movie, where: m.id == ^movie.id),
      set: [verification_hold_origin: hold_origin]
    )

    movie
  end

  defp movie_in(status), do: movie_fixture(status: status)
end
