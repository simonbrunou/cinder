defmodule Cinder.Library.AnimePreflightTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.AnimePreflight

  @fixture_path "test/support/fixtures/anime/import-v1.json"
  @external_resource @fixture_path
  @corpus @fixture_path |> File.read!() |> Jason.decode!()
  @cases @corpus["cases"]

  assert @corpus["version"] == 1
  assert length(@cases) == 22

  for fixture <- @cases do
    test fixture["id"] do
      fixture = unquote(Macro.escape(fixture))
      expected = fixture["expected"]

      case expected["status"] do
        "resolved" ->
          assert {:ok, result} = run_fixture(fixture)
          assert assignment_map(result.assignments) == expected["assignments"]
          assert result.decisions == expected["decisions"]
          assert Jason.encode(result) |> elem(0) == :ok

        "needs_mapping" ->
          assert {:needs_mapping, result} = run_fixture(fixture)
          assert result.issue["reason"] == expected["reason"]
          assert result.issue == expected["issue"]
          assert result.decisions == expected["decisions"]
          assert Jason.encode(result) |> elem(0) == :ok
      end

      paths = Enum.map(expected["decisions"]["files"], & &1["relative_path"])
      assert paths == Enum.sort(paths)
    end
  end

  test "resolved decisions expose parser and resolver evidence without source paths" do
    fixture = Enum.find(@cases, &(&1["id"] == "single-standard"))

    assert {:ok, %{decisions: decisions} = result} = run_fixture(fixture)
    assert [%{"parsed" => parsed, "evidence" => evidence}] = decisions["files"]
    assert Map.keys(parsed) |> Enum.sort() == ~w(coordinates group role)
    assert [%{"resolver" => %{"matches" => [_]}}] = evidence["resolutions"]

    json = Jason.encode!(result)
    refute json =~ "absolute_path"
    refute json =~ "source_path"
    refute json =~ fixture["absolute_download_root"]
  end

  defp run_fixture(fixture) do
    snapshot = %{
      "version" => fixture["snapshot_version"],
      "parser_context" => fixture["parser_context"],
      "mappings" => fixture["mappings"]
    }

    inventory =
      Enum.map(fixture["inventory"], fn entry ->
        %{
          relative_path: entry["relative_path"],
          identity: %{
            size: entry["size"],
            major_device: entry["major_device"],
            inode: entry["inode"],
            mtime: entry["mtime"]
          }
        }
      end)

    episodes =
      Enum.map(fixture["episodes"], fn episode ->
        %{
          id: episode["id"],
          season_number: episode["season_number"],
          episode_number: episode["episode_number"]
        }
      end)

    AnimePreflight.run(snapshot, inventory, fixture["overrides"], episodes)
  end

  defp assignment_map(assignments) do
    Map.new(assignments, &{&1.relative_path, &1.episode_ids})
  end
end
