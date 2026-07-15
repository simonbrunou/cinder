defmodule Cinder.Library.AnimePreflightTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.AnimePreflight

  @fixture_path "test/support/fixtures/anime/import-v1.json"
  @external_resource @fixture_path
  @corpus @fixture_path |> File.read!() |> Jason.decode!()
  # ponytail: snapshot version 1 (never-shipped legacy format) has no runtime path anymore;
  # its two fixture cases stay in the shared fixture file but are excluded here. The grab-local
  # manual-override/correction workflow was deleted too (replaced by a plain hold + operator
  # retry); "manual-ignored-extra"/"override-success"/"override-conflict" exist only to exercise
  # that override input, and "inventory-mutation" only reaches its expected outcome via a stale
  # override — it stays in the fixture file (library_test.exs still consumes it directly, via
  # before/after inventory fields, for the unrelated staging-time mutated-inventory check) but is
  # excluded here since `AnimePreflight.run/3` no longer takes overrides at all.
  @override_only_cases ~w(manual-ignored-extra override-success override-conflict inventory-mutation)
  @cases Enum.reject(
           @corpus["cases"],
           &(&1["snapshot_version"] == 1 or &1["id"] in @override_only_cases)
         )

  assert @corpus["version"] == 1
  assert length(@cases) == 16

  for fixture <- @cases do
    test fixture["id"] do
      fixture = unquote(Macro.escape(fixture))
      expected = fixture["expected"]

      assert Enum.sort(fixture["files"]) ==
               fixture["inventory"] |> Enum.map(& &1["relative_path"]) |> Enum.sort()

      assert fixture["authoritative_episode_ids"] == Enum.map(fixture["episodes"], & &1["id"])

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

  describe "lone-file release inference (issue #123)" do
    test "an unparseable file resolves via release inference when exactly one episode is reserved" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "cinder-a1b2c3d4e5f6.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:ok, result} = run_fixture(fixture)
      assert assignment_map(result.assignments) == %{"cinder-a1b2c3d4e5f6.mkv" => [101]}

      assert [%{"source" => "release_inference", "evidence" => evidence}] =
               result.decisions["files"]

      assert evidence == %{"resolution" => "release_inference"}
    end

    test "a second file in the inventory still needs mapping even with one reserved episode" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [
          %{
            "identity" => %{
              "source" => "cinder",
              "scheme" => "standard",
              "namespace" => "canonical",
              "canonical_value" => "S01E01"
            },
            "precedence" => "manual",
            "episode_ids" => [101],
            "evidence" => nil
          }
        ],
        "inventory" => [
          %{
            "relative_path" => "Frieren - S01E01.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          },
          %{
            "relative_path" => "cinder-a1b2c3d4e5f6.mkv",
            "size" => 1001,
            "major_device" => 1,
            "inode" => 201,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "unresolved_file"
      assert result.issue["relative_paths"] == ["cinder-a1b2c3d4e5f6.mkv"]
    end

    test "a lone unparseable file with two reserved episodes still needs mapping" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "cinder-a1b2c3d4e5f6.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          }
        ],
        "episodes" => [
          %{"id" => 101, "season_number" => 1, "episode_number" => 1},
          %{"id" => 102, "season_number" => 1, "episode_number" => 2}
        ]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "unresolved_file"
    end

    test "a lone file with an ambiguous resolution still needs mapping" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [
          %{
            "identity" => %{
              "source" => "one",
              "scheme" => "standard",
              "namespace" => "canonical",
              "canonical_value" => "S01E01"
            },
            "precedence" => "manual",
            "episode_ids" => [101],
            "evidence" => nil
          },
          %{
            "identity" => %{
              "source" => "two",
              "scheme" => "standard",
              "namespace" => "alt",
              "canonical_value" => "S01E01"
            },
            "precedence" => "manual",
            "episode_ids" => [102],
            "evidence" => nil
          }
        ],
        "inventory" => [
          %{
            "relative_path" => "Frieren - S01E01.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "unresolved_file"

      assert [%{"evidence" => %{"resolution" => "ambiguous"}}] = result.decisions["files"]
    end
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

    AnimePreflight.run(snapshot, inventory, episodes)
  end

  defp assignment_map(assignments) do
    Map.new(assignments, &{&1.relative_path, &1.episode_ids})
  end
end
