defmodule Cinder.Catalog.MovieTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Movie
  import Ecto.Changeset

  test "changeset/2 casts original_language and preferred_language" do
    cs =
      Movie.changeset(%Movie{}, %{
        tmdb_id: 1,
        title: "X",
        original_language: "fr",
        preferred_language: "french"
      })

    assert cs.valid?
    assert get_change(cs, :original_language) == "fr"
    assert get_change(cs, :preferred_language) == "french"
  end

  test "language_changeset/2 casts only preferred_language" do
    cs = Movie.language_changeset(%Movie{}, %{preferred_language: "any", status: :available})
    assert get_change(cs, :preferred_language) == "any"
    assert get_change(cs, :status) == nil
  end

  test "transition_changeset/2 casts imported_source" do
    cs = Movie.transition_changeset(%Movie{}, %{status: :available, imported_source: "bluray"})
    assert cs.changes.imported_source == "bluray"
  end
end
