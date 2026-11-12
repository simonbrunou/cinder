defmodule Cinder.Requests.Approval.MovieTest do
  # The movie adapter's post-commit language fill for an existing movie. The approval has
  # committed by then, so a failed fill only logs, and a profile the approval changed is still
  # announced.
  use Cinder.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cinder.Catalog
  alias Cinder.Requests.Approval
  alias Cinder.Requests.Request

  defp publish_existing(movie, preferred, profile_changed?) do
    Approval.Movie.publish(
      %{
        outcome: :existing,
        movie: movie,
        preferred: preferred,
        pre_request_profile: :auto,
        profile_changed?: profile_changed?
      },
      %Request{id: 4242}
    )
  end

  test "a fill that fails logs a warning and still announces a changed profile" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 603, title: "The Matrix"})
    Catalog.subscribe()
    movie_id = movie.id

    log =
      capture_log(fn ->
        # Not a language pick the movie accepts, so the fill's changeset fails.
        assert :ok = publish_existing(movie, "not-a-language", true)
      end)

    assert log =~ "apply_confirmed_media for movie #{movie_id} (request 4242) failed"
    assert_receive {:movie_updated, %{id: ^movie_id}}
    assert Repo.reload!(movie).preferred_language == "original"
  end

  test "a fill that succeeds announces the filled movie once" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 603, title: "The Matrix"})
    Catalog.subscribe()
    movie_id = movie.id

    assert :ok = publish_existing(movie, "french", true)

    assert_receive {:movie_updated, %{id: ^movie_id, preferred_language: "french"}}
    refute_receive {:movie_updated, %{id: ^movie_id}}
    assert %{preferred_language: "french", media_profile: :auto} = Repo.reload!(movie)
  end
end
