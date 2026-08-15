defmodule Cinder.Catalog.ProfilesTest do
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Profile, Series}
  alias Cinder.Requests
  alias Cinder.Requests.Request

  import Cinder.AccountsFixtures

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
