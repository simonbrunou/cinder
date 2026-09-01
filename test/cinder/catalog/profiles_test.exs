defmodule Cinder.Catalog.ProfilesTest do
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Profile, Series}
  alias Cinder.Requests
  alias Cinder.Requests.Request
  alias Ecto.Adapters.SQL

  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  test "validates names and explicit roots" do
    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "  Kids  ",
               kind: :movies,
               handling: :standard,
               library_path: "/srv/media/kids"
             })

    assert profile.name == "Kids"

    assert {:error, duplicate} =
             Catalog.create_profile(%{name: "kids", kind: :movies, handling: :anime})

    assert "has already been taken" in errors_on(duplicate).name

    for path <- ["relative", "/", "/srv/media/../movies"] do
      assert {:error, changeset} =
               Catalog.create_profile(%{
                 name: "Bad #{path}",
                 kind: :tv,
                 handling: :standard,
                 library_path: path
               })

      assert errors_on(changeset).library_path != []
    end

    assert {:error, duplicate_root} =
             Catalog.create_profile(%{
               name: "Other",
               kind: :movies,
               handling: :anime,
               library_path: "/srv/media/kids"
             })

    assert "has already been taken" in errors_on(duplicate_root).library_path
  end

  test "ebook profiles accept only standard handling and can be listed" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{name: "Ereader", kind: :ebook, handling: :standard})

    assert Catalog.list_profiles(:ebook) == [ebook]

    assert {:error, changeset} =
             Catalog.create_profile(%{name: "Anime", kind: :ebook, handling: :anime})

    assert errors_on(changeset).handling != []
  end

  test "requests cannot reference an ebook profile" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{name: "Ereader", kind: :ebook, handling: :standard})

    assert_raise Exqlite.Error, ~r/requests_profile_integrity/, fn ->
      SQL.query!(
        Repo,
        """
        INSERT INTO requests (
          user_id, target_type, target_id, status, proposed_media_profile,
          proposed_profile_id, inserted_at, updated_at
        ) VALUES (?, 'movie', 90000, 'pending', 'standard', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [user_fixture().id, ebook.id]
      )
    end
  end

  test "an unreferenced ebook profile stays deletable even as the kind's only one" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{name: "Ereader", kind: :ebook, handling: :standard})

    # Ebooks are seeded with no profile, so zero is their valid state — the last-profile guard
    # that protects movie/TV routing must not strand an accidental book profile forever.
    assert {:ok, _deleted} = Catalog.delete_profile(ebook)
    assert Catalog.list_profiles(:ebook) == []
  end

  test "a book-referenced ebook profile cannot change library path" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{
               name: "Ereader",
               kind: :ebook,
               handling: :standard,
               library_path: "/srv/media/ebooks"
             })

    assert {:ok, work} =
             Books.upsert_work(%{
               title: "Referenced work",
               identifier: %{provider: "openlibrary", kind: "work", foreign_id: "referenced-work"}
             })

    assert {:ok, target} = Books.ensure_target(work, :ebook)

    assert {:ok, _target} =
             target
             |> BookTarget.create_changeset(%{profile_id: ebook.id})
             |> Repo.update()

    assert {:error, changeset} =
             Catalog.update_profile(ebook, %{library_path: "/srv/media/other-ebooks"})

    assert "referenced profile may only be renamed" in errors_on(changeset).base
    assert Repo.reload!(ebook).library_path == "/srv/media/ebooks"
  end

  test "a profile referenced only by a live author policy cannot change kind, and cannot be
        deleted" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{name: "Policy eBooks", kind: :ebook, handling: :standard})

    assert {:ok, author} =
             Books.upsert_author(%{
               name: "Policied Author",
               identifier: %{provider: "openlibrary", kind: "author", foreign_id: "policy-author"}
             })

    assert {:ok, _policy} = Books.set_author_policy(author, :all, ebook)

    # No `book_targets` row exists at all yet — the reference is the policy row alone. A kind
    # change here would leave the policy pointing at a profile `Books.monitor_target/4` refuses
    # every candidate against forever, with nothing logged to say why.
    assert {:error, changeset} = Catalog.update_profile(ebook, %{kind: :audiobook})
    assert "referenced profile may only be renamed" in errors_on(changeset).base
    assert Repo.reload!(ebook).kind == :ebook

    assert {:error, :in_use} = Catalog.delete_profile(ebook)
  end

  test "movies cannot reference an ebook profile after the profile table rebuild" do
    assert {:ok, ebook} =
             Catalog.create_profile(%{name: "Ereader", kind: :ebook, handling: :standard})

    assert_raise Exqlite.Error, ~r/movies_profile_integrity/, fn ->
      SQL.query!(
        Repo,
        """
        INSERT INTO movies (
          tmdb_id, title, media_profile, profile_id, inserted_at, updated_at
        ) VALUES (90000, 'Wrong kind', 'standard', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [ebook.id]
      )
    end
  end

  test "assigns matching profiles and synchronizes legacy handling in one update" do
    movie =
      %Movie{}
      |> Movie.changeset(%{tmdb_id: 90_001, title: "Movie"})
      |> Repo.insert!()

    series =
      %{tmdb_id: 90_002, title: "Series"}
      |> Series.create_changeset()
      |> Repo.insert!()

    request =
      %Request{}
      |> Request.create_changeset(%{
        user_id: user_fixture().id,
        target_type: "movie",
        target_id: 90_001,
        status: :pending
      })
      |> Repo.insert!()

    movie_anime = profile!(:movies, :anime)
    tv_anime = profile!(:tv, :anime)

    assert {:ok, assigned_movie} = Catalog.assign_profile(movie, movie_anime)
    assert {assigned_movie.profile_id, assigned_movie.media_profile} == {movie_anime.id, :anime}

    assert {:ok, assigned_series} = Catalog.assign_profile(series, tv_anime)
    assert {assigned_series.profile_id, assigned_series.media_profile} == {tv_anime.id, :anime}

    assert {:ok, assigned_request} = Requests.assign_profile(request, movie_anime)

    assert {assigned_request.proposed_profile_id, assigned_request.proposed_media_profile} ==
             {movie_anime.id, :anime}

    assert {:error, :wrong_profile_kind} = Catalog.assign_profile(movie, tv_anime)
    assert {:error, :wrong_profile_kind} = Requests.assign_profile(request, tv_anime)
    assert Repo.get!(Movie, movie.id).profile_id == movie_anime.id
  end

  test "referenced profiles may only be renamed and cannot be deleted" do
    profile = profile!(:movies, :standard)

    movie =
      %Movie{}
      |> Movie.changeset(%{tmdb_id: 90_003, title: "Referenced"})
      |> Repo.insert!()

    assert {:ok, _movie} = Catalog.assign_profile(movie, profile)
    assert {:ok, renamed} = Catalog.update_profile(profile, %{name: "Main"})
    assert renamed.name == "Main"

    assert {:error, changeset} = Catalog.update_profile(renamed, %{handling: :anime})
    assert "referenced profile may only be renamed" in errors_on(changeset).base
    assert {:error, :in_use} = Catalog.delete_profile(renamed)
  end

  test "movie profile assignment keeps every existing primary and part file fenced" do
    root = "/tmp/cinder-profile-fence-movies"

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Movie fence",
               kind: :movies,
               handling: :standard,
               library_path: root
             })

    movie = movie_fixture(%{file_path: "#{root}/Movie/Movie.mkv"})

    assert {:ok, movie} =
             Catalog.transition(movie, %{
               status: movie.status,
               part_file_paths: ["#{root}/Movie/Movie-cd2.mkv"]
             })

    assert {:ok, assigned} = Catalog.assign_profile(movie, profile)
    assert assigned.profile_id == profile.id

    assert {:error, :files_outside_profile_root} = Catalog.assign_profile(assigned, nil)
    assert Repo.reload!(assigned).profile_id == profile.id

    split_stack = movie_fixture(%{file_path: "#{root}/Split/Split.mkv"})

    assert {:ok, split_stack} =
             Catalog.transition(split_stack, %{
               status: split_stack.status,
               part_file_paths: ["/tmp/outside-profile/Split-cd2.mkv"]
             })

    assert {:error, :files_outside_profile_root} = Catalog.assign_profile(split_stack, profile)
    assert Repo.reload!(split_stack).profile_id == nil
    assert {:error, :in_use} = Catalog.delete_profile(profile)
  end

  test "series profile assignment keeps every episode primary and part file fenced" do
    root = "/tmp/cinder-profile-fence-tv"

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "TV fence",
               kind: :tv,
               handling: :anime,
               library_path: root
             })

    series = series_fixture()
    season = season_fixture(series)
    episode = episode_fixture(season)

    assert {:ok, _episode} =
             Catalog.transition_episode(episode, %{
               file_path: "#{root}/Show/S01E01.mkv",
               part_file_paths: ["#{root}/Show/S01E01-part2.mkv"]
             })

    assert {:ok, assigned} = Catalog.assign_profile(series, profile)
    assert {assigned.profile_id, assigned.media_profile} == {profile.id, :anime}

    assert {:error, :files_outside_profile_root} = Catalog.assign_profile(assigned, nil)
    assert Repo.reload!(assigned).profile_id == profile.id

    outside = episode_fixture(season, %{episode_number: 2})

    assert {:ok, _episode} =
             Catalog.transition_episode(outside, %{
               file_path: "#{root}/Show/S01E02.mkv",
               part_file_paths: ["/tmp/outside-profile/S01E02-part2.mkv"]
             })

    assert {:error, :files_outside_profile_root} = Catalog.assign_profile(assigned, profile)
    assert Repo.reload!(assigned).profile_id == profile.id
  end

  test "profile assignment is blocked while an acquisition can still import into the old root" do
    movie = movie_fixture()
    assert {:ok, movie} = Catalog.transition(movie, %{status: :searching})

    assert {:error, :acquisition_in_progress} =
             Catalog.assign_profile(movie, profile!(:movies, :anime))

    series = series_fixture()
    episode = series |> season_fixture() |> episode_fixture()
    assert {:ok, _grab} = Catalog.create_grab("profile-race", :torrent, [episode.id])

    assert {:error, :acquisition_in_progress} =
             Catalog.assign_profile(series, profile!(:tv, :anime))
  end

  test "each kind retains one profile" do
    for profile <- Catalog.list_profiles(:tv) |> Enum.drop(1) do
      assert {:ok, _profile} = Catalog.delete_profile(profile)
    end

    assert [last] = Catalog.list_profiles(:tv)
    assert {:error, :last_profile} = Catalog.delete_profile(last)
  end

  test "database integrity maps bypassed profile ids back to changeset errors" do
    movie_profile = profile!(:movies, :standard)
    tv_profile = profile!(:tv, :standard)

    assert {:error, movie_changeset} =
             %Movie{}
             |> Movie.changeset(%{
               tmdb_id: 90_004,
               title: "Wrong kind",
               media_profile: :standard,
               profile_id: tv_profile.id
             })
             |> Repo.insert()

    assert "is invalid" in errors_on(movie_changeset).profile_id

    assert {:error, request_changeset} =
             %Request{}
             |> Request.create_changeset(%{
               user_id: user_fixture().id,
               target_type: "movie",
               target_id: 90_004,
               status: :pending,
               proposed_media_profile: :standard,
               proposed_profile_id: tv_profile.id
             })
             |> Repo.insert()

    assert "is invalid" in errors_on(request_changeset).proposed_profile_id

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: 90_005,
        title: "Referenced",
        media_profile: :standard,
        profile_id: movie_profile.id
      })
      |> Repo.insert!()

    assert movie.profile_id == movie_profile.id

    assert {:error, profile_changeset} =
             movie_profile
             |> Profile.changeset(%{handling: :anime})
             |> Repo.update()

    assert "is invalid" in errors_on(profile_changeset).handling
  end

  defp profile!(kind, handling) do
    Catalog.list_profiles(kind) |> Enum.find(&(&1.handling == handling))
  end
end
