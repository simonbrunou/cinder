defmodule Cinder.Indexers.DefinitionsSettingsTest do
  # What the definitions line and the add list of /settings read from `Definitions` (#1676): each
  # picker row's display name, the running copy's hash an edit form carries, the held update an
  # Accept confirms, and when the definitions were last checked.
  use Cinder.DataCase, async: true

  import Cinder.DefinitionFixtures

  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{LoadResult, UpdateRun}

  @base definition()

  test "a picker row carries the copy's display name, and a copy that fails carries none" do
    assert {:ok, {:loaded, _}} =
             apply_files([{"v11", "tracker.yml", @base}, {"v11", "broken.yml", failing("x")}])

    assert %{title: "Cinder Test tracker", result: :loads} = row("tracker.yml")
    assert %{title: nil, result: {:fails, _}} = row("broken.yml")
  end

  test "a result stored under an older revision reads unchecked, with no name" do
    mirror!(@base)
    Repo.update_all(LoadResult, inc: [revision: -1])
    assert %{title: nil, result: :unchecked} = row("tracker.yml")
  end

  test "running_blob_sha/1 is the running copy's hash, nil with no pin" do
    mirror!(@base)
    row = cardigann!(@base)
    assert Definitions.running_blob_sha(row.id) == blob_sha(@base)
    assert Definitions.running_blob_sha(row.id + 1_000) == nil
  end

  test "held_update/1 names the held copy, the hold's reason and the hosts it adds" do
    mirror!(@base)
    row = cardigann!(@base, %{"password" => "hunter2"})
    hosted = definition("tracker", %{"description" => "https://new.invalid/"})
    mirror!(hosted)

    assert Definitions.held_update(row.id) ==
             {:ok, %{blob_sha: blob_sha(hosted), reason: :hosts, hosts: ["new.invalid"]}}

    assert Definitions.held_update(cardigann!(hosted).id) == {:error, :stale}
  end

  # The confirms render these hosts, so a host built from a stored secret shows as its template
  # text, never as the secret: `https://{{ .Config.password }}.x` would show the password.
  describe "a host built from a stored secret shows as its template" do
    setup do
      mirror!(@base)
      row = cardigann!(@base, %{"password" => "hunter2", "username" => "https://own.invalid/"})
      %{row: row}
    end

    test "in held_update/1, for a templated host and for a secret that holds a URL", %{row: row} do
      hosted =
        definition("tracker", %{
          "description" => "https://{{ .Config.password }}.evil.invalid/ {{ .Config.username }}"
        })

      mirror!(hosted)
      assert {:ok, %{reason: :hosts, hosts: hosts}} = Definitions.held_update(row.id)

      assert hosts == [
               {:unknown, "https://{{ .Config.password }}.evil.invalid"},
               {:unknown, "{{ .Config.username }}"}
             ]
    end
  end

  describe "last_checked_at/0" do
    test "nil before any load" do
      assert Definitions.last_checked_at() == nil
    end

    test "the later of the last successful run and the loaded set's time" do
      mirror!(@base)
      loaded_at = Definitions.loaded().loaded_at
      assert Definitions.last_checked_at() == loaded_at

      later = DateTime.add(loaded_at, 3600)
      run!(later)
      assert Definitions.last_checked_at() == later

      run!(DateTime.add(loaded_at, -3600))
      assert Definitions.last_checked_at() == loaded_at
    end
  end

  defp row(name), do: Enum.find(Definitions.picker(), &(&1.name == name))

  defp run!(at) do
    at = DateTime.truncate(at, :second)

    Repo.insert!(
      %UpdateRun{
        id: UpdateRun.id(),
        started_at: at,
        ended_at: at,
        outcome: :unchanged,
        last_success_at: at
      },
      on_conflict: {:replace, [:last_success_at]},
      conflict_target: :id
    )
  end
end
