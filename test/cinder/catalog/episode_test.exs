defmodule Cinder.Catalog.EpisodeTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Episode

  test "transition_changeset/2 casts the pipeline fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{
        file_path: "/library/x.mkv",
        grab_id: 7,
        search_attempts: 2,
        import_attempts: 1
      })

    assert cs.valid?

    assert cs.changes == %{
             file_path: "/library/x.mkv",
             grab_id: 7,
             search_attempts: 2,
             import_attempts: 1
           }
  end

  test "transition_changeset/2 does not cast identity/monitoring fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{episode_number: 9, monitored: false, title: "x"})

    assert cs.changes == %{}
  end
end
