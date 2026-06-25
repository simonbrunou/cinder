defmodule Cinder.Catalog.SeriesTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Series
  import Ecto.Changeset

  test "create_changeset/1 casts language fields; language_changeset/2 casts only preferred_language" do
    cs =
      Series.create_changeset(%{
        tmdb_id: 9,
        title: "S",
        original_language: "fr",
        preferred_language: "original"
      })

    assert get_change(cs, :original_language) == "fr"
    # preferred_language matches the schema default so get_field, not get_change
    assert get_field(cs, :preferred_language) == "original"

    edit =
      Series.language_changeset(%Cinder.Catalog.Series{}, %{
        preferred_language: "french",
        monitored: false
      })

    assert get_change(edit, :preferred_language) == "french"
    assert get_change(edit, :monitored) == nil
  end
end
