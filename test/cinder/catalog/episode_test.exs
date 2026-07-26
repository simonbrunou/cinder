defmodule Cinder.Catalog.EpisodeTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Episode

  test "transition_changeset/2 casts the pipeline fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{
        file_path: "/library/x.mkv",
        search_attempts: 2
      })

    assert cs.valid?

    assert cs.changes == %{
             file_path: "/library/x.mkv",
             search_attempts: 2
           }
  end

  test "transition_changeset/2 casts grab_id alone" do
    cs = Episode.transition_changeset(%Episode{}, %{grab_id: 7})
    assert cs.valid?
    assert cs.changes == %{grab_id: 7}
  end

  test "transition_changeset/2 rejects setting file_path and grab_id together (never both)" do
    cs =
      Episode.transition_changeset(%Episode{}, %{
        file_path: "/library/x.mkv",
        grab_id: 7
      })

    refute cs.valid?
    assert cs.errors[:grab_id] == {"cannot be set while file_path is also set", []}
  end

  test "transition_changeset/2 rejects a negative search_attempts" do
    cs = Episode.transition_changeset(%Episode{}, %{search_attempts: -1})
    refute cs.valid?
    assert {"must be greater than or equal to %{number}", _} = cs.errors[:search_attempts]
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

  test "codes_label/2 collapses a single number, a contiguous run, or lists a gappy set" do
    assert Episode.codes_label(1, [5]) == "S01E05"
    assert Episode.codes_label(1, [5, 6, 7]) == "S01E05-E07"
    assert Episode.codes_label(1, [5, 7, 9]) == "S01E05E07E09"
  end
end
