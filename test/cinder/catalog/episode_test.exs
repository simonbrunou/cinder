defmodule Cinder.Catalog.EpisodeTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Episode

  test "transition_changeset/2 casts the pipeline fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{
        file_path: "/library/x.mkv",
        grab_id: 7,
        search_attempts: 2
      })

    assert cs.valid?

    assert cs.changes == %{
             file_path: "/library/x.mkv",
             grab_id: 7,
             search_attempts: 2
           }
  end

  test "transition_changeset/2 does not cast identity/monitoring fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{episode_number: 9, monitored: false, title: "x"})

    assert cs.changes == %{}
  end

  test "transition_changeset/2 casts imported_source" do
    cs = Episode.transition_changeset(%Episode{}, %{imported_source: "webdl"})
    assert cs.changes.imported_source == "webdl"
  end

  test "season_from_code/1 inverts code/2" do
    assert Episode.season_from_code(Episode.code(3, 12)) == 3
    assert Episode.season_from_code("S01E02") == 1
    assert Episode.season_from_code("garbage") == nil
  end
end
