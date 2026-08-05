defmodule Cinder.Library.AnimePreflightTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.{Episode, TitleAlias}
  alias Cinder.Download.Intent
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

  test "frozen snapshot mappings uniquely and completely cover reserved episode IDs" do
    fixture = Enum.find(@cases, &(&1["id"] == "single-standard"))

    snapshot =
      fixture
      |> snapshot_from_fixture()
      |> Map.put("version", 3)
      |> update_in(["parser_context"], fn context ->
        context
        |> Map.put("blocked_titles", [])
        |> Map.put("allow_unscoped_standard", false)
      end)

    assert Intent.valid_preflight_snapshot?(snapshot)

    [mapping | _] = snapshot["mappings"]
    [reserved_id | _] = snapshot["reserved_episode_ids"]

    invalid_snapshots = [
      Map.delete(snapshot, "release"),
      Map.delete(snapshot, "selected_resolution"),
      Map.put(snapshot, "mappings", []),
      Map.put(snapshot, "mappings", [mapping, mapping]),
      Map.put(snapshot, "reserved_episode_ids", [reserved_id, reserved_id]),
      Map.put(snapshot, "reserved_episode_ids", [reserved_id, reserved_id + 1])
    ]

    for invalid <- invalid_snapshots do
      refute Intent.valid_preflight_snapshot?(invalid)
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
        "mappings" => [
          %{
            "identity" => %{
              "source" => "cinder",
              "scheme" => "standard",
              "namespace" => "canonical",
              "canonical_value" => "S01E01"
            },
            "precedence" => "curated",
            "episode_ids" => [101],
            "evidence" => nil
          }
        ],
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

    test "recognized no-coordinate titles and metadata preserve lone-file release inference" do
      checksum_paths =
        for width <- [8, 32, 40, 64] do
          "Show [#{String.pad_trailing("E03", width, "A")}].mkv"
        end

      cases =
        [
          {"11.22.63.mkv", "11.22.63"},
          {"Show [23.976 fps].mkv", "Show"},
          {"Show [5.1CH].mkv", "Show"},
          {"Show [2021.03.05].mkv", "Show"},
          {"Show [2021.03].mkv", "Show"},
          {"Show [H 264].mkv", "Show"},
          {"Show.cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv", "Show"}
        ] ++ Enum.map(checksum_paths, &{&1, "Show"})

      for snapshot_version <- [2, 3], {relative_path, title} <- cases do
        parser_context = %{"title" => title, "aliases" => [], "year" => 2021}

        parser_context =
          if snapshot_version == 3,
            do:
              Map.merge(parser_context, %{
                "blocked_titles" => [],
                "allow_unscoped_standard" => false
              }),
            else: parser_context

        fixture = %{
          "snapshot_version" => snapshot_version,
          "parser_context" => parser_context,
          "mappings" => [
            %{
              "identity" => %{
                "source" => "cinder",
                "scheme" => "standard",
                "namespace" => "canonical",
                "canonical_value" => "S01E01"
              },
              "precedence" => "curated",
              "episode_ids" => [101],
              "evidence" => nil
            }
          ],
          "inventory" => [
            %{
              "relative_path" => relative_path,
              "size" => 1000,
              "major_device" => 1,
              "inode" => 200,
              "mtime" => 100
            }
          ],
          "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
        }

        assert {:ok, result} = run_fixture(fixture)
        assert assignment_map(result.assignments) == %{relative_path => [101]}

        assert [%{"source" => "release_inference"}] = result.decisions["files"]
      end
    end

    # The import-v1.json `unmatched-story-file` case pins the parsed-but-unmapped mechanism, but
    # there the file's coordinate happens to MATCH its episode — this test pins the semantic
    # danger the guard exists for: the lone file names a DIFFERENT episode than the one reserved.
    test "a lone file naming a different episode than the reserved one still needs mapping" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "Frieren - S01E03.mkv",
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
      assert result.issue["relative_paths"] == ["Frieren - S01E03.mkv"]
    end

    test "malformed and blocked coordinate evidence can never fall back to lone-file inference" do
      cases = [
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02-E03.mkv", []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01(E02).mkv", []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-S1000E01.mkv", []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02 x264E03.mkv",
         []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02 x264S01E03.mkv",
         []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02 CRC32E03.mkv",
         []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02 AV1E03.mkv", []},
        {%{"title" => "Show", "aliases" => [], "year" => 2020}, "Show S01E01-E02 WEBE03.mkv", []},
        {%{
           "title" => "Foo",
           "aliases" => [],
           "blocked_titles" => ["Foo"],
           "year" => 2020
         }, "Foo 2 - 05.mkv", []},
        {%{
           "title" => "Show",
           "aliases" => [],
           "blocked_titles" => ["Foo"],
           "year" => 2020
         }, "Foo 2 - 05.mkv", []},
        {%{
           "title" => "Foo",
           "aliases" => [],
           "blocked_titles" => ["Foo"],
           "year" => 2020
         }, "Foo 2 OVA.mkv",
         [
           %{
             "identity" => %{
               "source" => "cinder",
               "scheme" => "typed_special",
               "namespace" => "canonical",
               "canonical_value" => "OVA"
             },
             "precedence" => "manual",
             "episode_ids" => [101],
             "evidence" => nil
           }
         ]}
      ]

      for {parser_context, relative_path, mappings} <- cases do
        fixture = %{
          "snapshot_version" =>
            if(Map.has_key?(parser_context, "blocked_titles"), do: 3, else: 2),
          "parser_context" => parser_context,
          "mappings" => mappings,
          "inventory" => [
            %{
              "relative_path" => relative_path,
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
        assert result.issue["relative_paths"] == [relative_path]
      end
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

    test "a lone file with an out-of-reservation ambiguous mapping snapshot fails closed" do
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
      assert result.issue["reason"] == "invalid_snapshot"

      assert [%{"evidence" => %{"resolution" => "invalid_snapshot"}}] =
               result.decisions["files"]
    end
  end

  describe "snapshot-keyed lone-file inference (issue #126)" do
    test "a snapshot reserving two episodes still holds when live episodes have shrunk to one" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "reserved_episode_ids" => [101, 102],
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

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "reserved_set_divergence"
      assert result.issue["candidate_episode_ids"] == [102]
    end

    # PR #137 review: divergence must hold even when every remaining file maps cleanly — a
    # shrunken live set plus an ignorable sample would otherwise import as a partial grab.
    test "a cleanly-mapped file plus an ignored sample still holds when the reserved set diverged" do
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
        "reserved_episode_ids" => [101, 102],
        "inventory" => [
          %{
            "relative_path" => "Frieren - S01E01.mkv",
            "size" => 1_400_000_000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          },
          %{
            "relative_path" => "sample.mkv",
            "size" => 40 * 1024 * 1024,
            "major_device" => 1,
            "inode" => 201,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "reserved_set_divergence"
      assert result.issue["candidate_episode_ids"] == [102]
    end
  end

  describe "sample/preview file semantics (issue #125)" do
    test "a lone small sample file is ignored and the batch holds for a missing assignment" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "sample.mkv",
            "size" => 40 * 1024 * 1024,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "missing_episode_assignment"
      assert result.issue["candidate_episode_ids"] == [101]

      assert [%{"ignored" => true, "evidence" => %{"resolution" => "sample_ignored"}}] =
               result.decisions["files"]
    end

    test "a sample alongside a main file is ignored, letting lone-file inference import the main file" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "abc123.mkv",
            "size" => 1_400_000_000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          },
          %{
            "relative_path" => "abc123.sample.mkv",
            "size" => 40 * 1024 * 1024,
            "major_device" => 1,
            "inode" => 201,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:ok, result} = run_fixture(fixture)
      assert assignment_map(result.assignments) == %{"abc123.mkv" => [101]}

      decisions = Map.new(result.decisions["files"], &{&1["relative_path"], &1})
      assert decisions["abc123.sample.mkv"]["ignored"] == true
      assert decisions["abc123.mkv"]["source"] == "release_inference"
    end

    test "a full-size file with a sample token, and a word-internal match, are both left unresolved" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
        "mappings" => [],
        "inventory" => [
          %{
            "relative_path" => "Frieren.Sample.mkv",
            "size" => 900_000_000,
            "major_device" => 1,
            "inode" => 200,
            "mtime" => 100
          },
          %{
            "relative_path" => "Frieren.Sampler.mkv",
            "size" => 900_000_000,
            "major_device" => 1,
            "inode" => 201,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 101, "season_number" => 1, "episode_number" => 1}]
      }

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "unresolved_file"

      assert result.issue["relative_paths"] ==
               Enum.sort(["Frieren.Sample.mkv", "Frieren.Sampler.mkv"])

      refute Enum.any?(result.decisions["files"], & &1["ignored"])
    end
  end

  test "legacy version-2 replay keeps an exact standard coordinate under an alternate filename" do
    fixture = %{
      "snapshot_version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2020},
      "mappings" => [
        %{
          "identity" => %{
            "source" => "cinder",
            "scheme" => "standard",
            "namespace" => "canonical",
            "canonical_value" => "S01E01"
          },
          "precedence" => "curated",
          "episode_ids" => [11],
          "evidence" => nil
        }
      ],
      "reserved_episode_ids" => [11],
      "inventory" => [
        %{
          "relative_path" => "86 Eighty-Six S01E01.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 201,
          "mtime" => 100
        }
      ],
      "episodes" => [%{"id" => 11, "season_number" => 1, "episode_number" => 1}]
    }

    assert {:ok, result} = run_fixture(fixture)

    assert result.assignments == [
             %{relative_path: "86 Eighty-Six S01E01.mkv", episode_ids: [11]}
           ]

    for relative_path <- [
          "Show 2nd Season S01E01.mkv",
          "Show Part 2 S01E01.mkv",
          "Show 2 S01E01.mkv"
        ] do
      compatible_fixture =
        put_in(fixture, ["inventory", Access.at(0), "relative_path"], relative_path)

      assert {:ok, compatible_result} = run_fixture(compatible_fixture)

      assert compatible_result.assignments == [
               %{relative_path: relative_path, episode_ids: [11]}
             ]
    end

    metadata =
      [
        "Vol.1",
        "Volume 1",
        "Disc 1",
        "Part 1",
        "Batch 1",
        "2 Audio Tracks",
        "3 Subs",
        "Dual Audio 2 Subs",
        "2021",
        "2021-03-05",
        "2021.03",
        "H 264",
        "H 265"
      ] ++ Enum.map([8, 32, 40, 64], &String.pad_trailing("E03", &1, "A"))

    for metadata <- metadata do
      relative_path = "Show S01E01 [#{metadata}].mkv"

      metadata_fixture =
        put_in(fixture, ["inventory", Access.at(0), "relative_path"], relative_path)

      assert {:ok, metadata_result} = run_fixture(metadata_fixture)
      assert metadata_result.assignments == [%{relative_path: relative_path, episode_ids: [11]}]

      version3_fixture =
        metadata_fixture
        |> Map.put("snapshot_version", 3)
        |> put_in(
          ["parser_context"],
          %{
            "title" => "Show",
            "aliases" => [],
            "blocked_titles" => [],
            "allow_unscoped_standard" => false,
            "year" => 2020
          }
        )

      assert {:ok, version3_result} = run_fixture(version3_fixture)
      assert version3_result.assignments == [%{relative_path: relative_path, episode_ids: [11]}]
    end
  end

  test "frozen replay applies longer blocked titles before standard coordinates" do
    fixture = %{
      "snapshot_version" => 3,
      "parser_context" => %{
        "title" => "Foo",
        "aliases" => [],
        "blocked_titles" => ["Foo Bar"],
        "allow_unscoped_standard" => false,
        "year" => 2020
      },
      "mappings" => [
        %{
          "identity" => %{
            "source" => "cinder",
            "scheme" => "standard",
            "namespace" => "canonical",
            "canonical_value" => "S01E02"
          },
          "precedence" => "curated",
          "episode_ids" => [11],
          "evidence" => nil
        }
      ],
      "inventory" => [
        %{
          "relative_path" => "Foo Bar S01E02.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 201,
          "mtime" => 100
        }
      ],
      "episodes" => [%{"id" => 11, "season_number" => 1, "episode_number" => 2}]
    }

    assert {:needs_mapping, result} = run_fixture(fixture)
    assert result.issue["reason"] == "unresolved_file"
  end

  test "frozen replay does not reinterpret malformed coordinates as a typed special" do
    fixture = %{
      "snapshot_version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2020},
      "mappings" => [
        %{
          "identity" => %{
            "source" => "fixture",
            "scheme" => "typed_special",
            "namespace" => "main",
            "canonical_value" => "OVA:1"
          },
          "precedence" => "curated",
          "episode_ids" => [11],
          "evidence" => nil
        }
      ],
      "inventory" => [
        %{
          "relative_path" => "Show S01E01-E02-E03 OVA 1.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 201,
          "mtime" => 100
        }
      ],
      "episodes" => [%{"id" => 11, "season_number" => 0, "episode_number" => 1}]
    }

    uuid = ".cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv"

    for {malformed, suffix} <- [
          {"S01E01-E02-E03", ".mkv"},
          {"1-2-3", ".mkv"},
          {"01 WEB 02", ".mkv"},
          {"01-02 WEB 03", ".mkv"},
          {"01 WEB 02v2", ".mkv"},
          {"01 WEB 02话", ".mkv"},
          {"01 WEB 第02集", ".mkv"},
          {"01 WEB 02", uuid},
          {"01-02 WEB 03", uuid},
          {"01 WEB 02v2", uuid}
        ] do
      malformed_fixture =
        put_in(
          fixture,
          ["inventory", Access.at(0), "relative_path"],
          "Show #{malformed} OVA 1#{suffix}"
        )

      assert {:needs_mapping, result} = run_fixture(malformed_fixture)
      assert result.issue["reason"] == "unresolved_file"
    end
  end

  test "frozen replay rejects residual versioned and CJK absolute coordinates" do
    mappings =
      for {value, episode_id} <- [{"1", 11}, {"2", 12}] do
        %{
          "identity" => %{
            "source" => "cinder",
            "scheme" => "absolute",
            "namespace" => "canonical",
            "canonical_value" => value
          },
          "precedence" => "curated",
          "episode_ids" => [episode_id],
          "evidence" => nil
        }
      end

    fixture = %{
      "snapshot_version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2020},
      "mappings" => mappings,
      "inventory" => [
        %{
          "relative_path" => "Show 01-02 03v2.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 201,
          "mtime" => 100
        }
      ],
      "episodes" => [
        %{"id" => 11, "season_number" => 1, "episode_number" => 1},
        %{"id" => 12, "season_number" => 1, "episode_number" => 2}
      ]
    }

    for relative_path <- [
          "Show 01-02 03v2.mkv",
          "Show 01-02 03话.mkv",
          "Show 01-02 第03集.mkv",
          "Show 01 WEB 02v2.mkv"
        ] do
      malformed_fixture =
        put_in(fixture, ["inventory", Access.at(0), "relative_path"], relative_path)

      assert {:needs_mapping, result} = run_fixture(malformed_fixture)
      assert result.issue["reason"] == "unresolved_file"
    end
  end

  test "historical frozen replay preserves typed specials for numeric titles and dates" do
    fixture = %{
      "snapshot_version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2020},
      "mappings" => [
        %{
          "identity" => %{
            "source" => "fixture",
            "scheme" => "typed_special",
            "namespace" => "main",
            "canonical_value" => "OVA:1"
          },
          "precedence" => "curated",
          "episode_ids" => [11],
          "evidence" => nil
        }
      ],
      "inventory" => [
        %{
          "relative_path" => "Show OVA 1.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 201,
          "mtime" => 100
        }
      ],
      "episodes" => [%{"id" => 11, "season_number" => 0, "episode_number" => 1}]
    }

    for {relative_path, canonical_title} <- [
          {"11.22.63 OVA 1.mkv", "11.22.63"},
          {"Show [2021.03.05] OVA 1.mkv", "Show"},
          {"3-2-1 Penguins! OVA 1.mkv", "3-2-1 Penguins!"}
        ] do
      compatible_fixture =
        fixture
        |> put_in(["parser_context", "title"], canonical_title)
        |> put_in(["inventory", Access.at(0), "relative_path"], relative_path)

      assert {:ok, result} = run_fixture(compatible_fixture)
      assert result.assignments == [%{relative_path: relative_path, episode_ids: [11]}]
    end
  end

  describe "alternate scene numbering (A6)" do
    test "an arc-title file resolves through the frozen scene-title scope (issue #312)" do
      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{
          "title" => "Monogatari",
          "aliases" => ["Koyomimonogatari"],
          "scene_titles" => [
            %{
              "title" => "Koyomimonogatari",
              "season" => 11,
              "source" => "tmdb",
              "namespace" => "nisio-isin-order"
            }
          ],
          "year" => 2009
        },
        "mappings" => [
          %{
            "identity" => %{
              "source" => "tmdb",
              "scheme" => "scene",
              "namespace" => "nisio-isin-order",
              "canonical_value" => "S11E05"
            },
            "precedence" => "inferred",
            "episode_ids" => [17],
            "evidence" => nil,
            "scope_title" => "Koyomimonogatari"
          },
          %{
            "identity" => %{
              "source" => "manual",
              "scheme" => "scene",
              "namespace" => "other-order",
              "canonical_value" => "S11E05"
            },
            "precedence" => "manual",
            "episode_ids" => [17],
            "evidence" => nil
          }
        ],
        "inventory" => [
          %{
            "relative_path" => "Koyomimonogatari - 05.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 205,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 17, "season_number" => 0, "episode_number" => 17}]
      }

      scoped_identity = fixture["mappings"] |> hd() |> Map.fetch!("identity")

      snapshot =
        fixture
        |> snapshot_from_fixture()
        |> Map.update!("mappings", &Enum.take(&1, 1))
        |> Map.put("release", %{
          "title" => "Koyomimonogatari - 05",
          "coordinates" => [
            %{
              "scheme" => "scene",
              "values" => ["S11E05"],
              "source" => "tmdb",
              "namespace" => "nisio-isin-order",
              "scope_title" => "koyomimonogatari"
            }
          ],
          "group" => nil,
          "category_ids" => [],
          "indexer_id" => nil,
          "published_at" => nil
        })
        |> Map.put("selected_resolution", %{
          "episode_ids" => [17],
          "values" => [
            %{
              "scheme" => "scene",
              "canonical_value" => "S11E05",
              "episode_ids" => [17],
              "precedence" => "inferred",
              "mapping_identities" => [scoped_identity],
              "source" => "tmdb",
              "namespace" => "nisio-isin-order",
              "scope_title" => "koyomimonogatari"
            }
          ]
        })

      assert Intent.valid_mapping_snapshot?(snapshot, :episode, [17])
      assert {:ok, result} = run_fixture(fixture)
      assert assignment_map(result.assignments) == %{"Koyomimonogatari - 05.mkv" => [17]}

      assert [%{"parsed" => %{"coordinates" => [coordinate]}}] = result.decisions["files"]

      assert coordinate == %{
               "scheme" => "scene",
               "values" => ["S11E05"],
               "source" => "tmdb",
               "namespace" => "nisio-isin-order",
               "scope_title" => "koyomimonogatari"
             }
    end

    test "a longer canonical title outranks a scoped prefix during frozen replay" do
      absolute_mapping = %{
        "identity" => %{
          "source" => "fixture",
          "scheme" => "absolute",
          "namespace" => "main",
          "canonical_value" => "5"
        },
        "precedence" => "manual",
        "episode_ids" => [5],
        "evidence" => nil
      }

      scene_mappings =
        Enum.map(2..5, fn episode_number ->
          %{
            "identity" => %{
              "source" => "tmdb",
              "scheme" => "scene",
              "namespace" => "author-order",
              "canonical_value" => "S11E0#{episode_number}"
            },
            "precedence" => "inferred",
            "episode_ids" => [episode_number],
            "evidence" => nil,
            "scope_title" => "Foo"
          }
        end)

      fixture = %{
        "snapshot_version" => 2,
        "parser_context" => %{
          "title" => "Foo 2",
          "aliases" => ["Foo"],
          "scene_titles" => [
            %{
              "title" => "Foo",
              "season" => 11,
              "source" => "tmdb",
              "namespace" => "author-order"
            }
          ],
          "year" => 2020
        },
        "mappings" => [absolute_mapping, List.last(scene_mappings)],
        "reserved_episode_ids" => [5],
        "inventory" => [
          %{
            "relative_path" => "Foo 2 - 05.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 205,
            "mtime" => 100
          }
        ],
        "episodes" => [%{"id" => 5, "season_number" => 0, "episode_number" => 5}]
      }

      snapshot =
        fixture
        |> snapshot_from_fixture()
        |> Map.put("mappings", [absolute_mapping, List.last(scene_mappings)])
        |> Map.put("release", %{
          "title" => "Foo 2 - 05",
          "coordinates" => [%{"scheme" => "absolute", "values" => ["5"]}],
          "group" => nil,
          "category_ids" => [],
          "indexer_id" => nil,
          "published_at" => nil
        })
        |> Map.put("selected_resolution", %{
          "episode_ids" => [5],
          "values" => [
            %{
              "scheme" => "absolute",
              "canonical_value" => "5",
              "episode_ids" => [5],
              "precedence" => "manual",
              "mapping_identities" => [absolute_mapping["identity"]]
            }
          ]
        })

      assert Intent.valid_mapping_snapshot?(snapshot, :episode, [5])
      assert {:ok, result} = run_fixture(fixture)
      assert assignment_map(result.assignments) == %{"Foo 2 - 05.mkv" => [5]}

      assert [%{"parsed" => %{"coordinates" => [coordinate]}}] = result.decisions["files"]
      assert coordinate == %{"scheme" => "absolute", "values" => ["5"]}
    end

    test "S02E01..E10 files map to episodes 29-38 via the frozen snapshot" do
      fixture = frieren_scene_fixture(1..10)

      assert {:ok, result} = run_fixture(fixture)

      expected =
        Map.new(1..10, fn n ->
          {"Frieren - #{Episode.code(2, n)}.mkv", [n + 28]}
        end)

      assert assignment_map(result.assignments) == expected
    end

    test "one unmatched file among the batch still holds the whole grab" do
      extra_file = %{
        "relative_path" => "junk.mkv",
        "size" => 1,
        "major_device" => 1,
        "inode" => 999,
        "mtime" => 100
      }

      fixture =
        Map.update!(frieren_scene_fixture(1..10), "inventory", &(&1 ++ [extra_file]))

      assert {:needs_mapping, result} = run_fixture(fixture)
      assert result.issue["reason"] == "unresolved_file"
      assert result.issue["relative_paths"] == ["junk.mkv"]
    end
  end

  test "frozen replay honors a canonical title blocker from the bounded parser context" do
    fixture = %{
      "snapshot_version" => 3,
      "parser_context" => %{
        "title" => "Foo",
        "aliases" => ["A1", "A2", "A3", "A4", "A5", "A6", "A7"],
        "blocked_titles" => ["Foo"],
        "year" => 2020
      },
      "mappings" =>
        Enum.map(2..5, fn episode_number ->
          %{
            "identity" => %{
              "source" => "fixture",
              "scheme" => "absolute",
              "namespace" => "main",
              "canonical_value" => Integer.to_string(episode_number)
            },
            "episode_ids" => [episode_number],
            "precedence" => "manual",
            "evidence" => %{"kind" => "fixture"}
          }
        end),
      "reserved_episode_ids" => [2, 3, 4, 5],
      "episodes" =>
        Enum.map(2..5, fn episode_number ->
          %{
            "id" => episode_number,
            "season_number" => 0,
            "episode_number" => episode_number,
            "title" => "Episode #{episode_number}"
          }
        end),
      "inventory" => [
        %{
          "relative_path" => "[DB] Foo 2 - 05 [1080p].mkv",
          "extension" => ".mkv",
          "size" => 100,
          "sha256" => String.duplicate("a", 64)
        }
      ],
      "expected_inventory_paths" => ["[DB] Foo 2 - 05 [1080p].mkv"]
    }

    assert {:needs_mapping, result} = run_fixture(fixture)
    assert result.issue["reason"] == "unresolved_file"

    downgraded = update_in(fixture["parser_context"], &Map.delete(&1, "blocked_titles"))
    assert {:needs_mapping, downgraded_result} = run_fixture(downgraded)
    assert downgraded_result.issue["reason"] == "invalid_snapshot"

    standard_extension =
      fixture
      |> Map.put("reserved_episode_ids", [2])
      |> Map.put("episodes", [hd(fixture["episodes"])])
      |> Map.update!("mappings", fn mappings ->
        Enum.filter(mappings, &(&1["episode_ids"] == [2])) ++
          [
            %{
              "identity" => %{
                "source" => "cinder",
                "scheme" => "standard",
                "namespace" => "canonical",
                "canonical_value" => "S01E02"
              },
              "episode_ids" => [2],
              "precedence" => "manual",
              "evidence" => %{"kind" => "canonical_standard"}
            }
          ]
      end)
      |> put_in(
        ["inventory"],
        [
          %{
            "relative_path" => "[DB] Foo - The Arc S01E02 [1080p].mkv",
            "extension" => ".mkv",
            "size" => 100,
            "sha256" => String.duplicate("b", 64)
          }
        ]
      )

    assert {:needs_mapping, extension_result} = run_fixture(standard_extension)
    assert extension_result.issue["reason"] == "unresolved_file"
  end

  test "frozen replay rejects a scoped range that crosses into another subgroup title" do
    fixture = %{
      "snapshot_version" => 2,
      "parser_context" => %{
        "title" => "Show",
        "aliases" => ["Arc A"],
        "scene_titles" => [
          %{
            "title" => "Arc A",
            "season" => 11,
            "source" => "tmdb",
            "namespace" => "author-order"
          }
        ],
        "year" => 2020
      },
      "mappings" => [
        %{
          "identity" => %{
            "source" => "tmdb",
            "scheme" => "scene",
            "namespace" => "author-order",
            "canonical_value" => "S11E01"
          },
          "precedence" => "inferred",
          "scope_title" => "Arc A",
          "episode_ids" => [1],
          "evidence" => nil
        },
        %{
          "identity" => %{
            "source" => "tmdb",
            "scheme" => "scene",
            "namespace" => "author-order",
            "canonical_value" => "S11E02"
          },
          "precedence" => "inferred",
          "scope_title" => "Arc B",
          "episode_ids" => [2],
          "evidence" => nil
        }
      ],
      "inventory" => [
        %{
          "relative_path" => "Arc A 01-02.mkv",
          "size" => 1000,
          "major_device" => 1,
          "inode" => 200,
          "mtime" => 100
        }
      ],
      "episodes" => [
        %{"id" => 1, "season_number" => 0, "episode_number" => 1},
        %{"id" => 2, "season_number" => 0, "episode_number" => 2}
      ]
    }

    assert {:needs_mapping, result} = run_fixture(fixture)
    assert result.issue["reason"] == "invalid_snapshot"

    safe_fixture =
      put_in(
        fixture,
        ["mappings"],
        Enum.map(fixture["mappings"], &Map.put(&1, "scope_title", "Arc A"))
      )

    for relative_path <- [
          "Arc A 01-02-03.mkv",
          "Arc A 01-02--03.mkv",
          "Arc A 01-02-2020-03.mkv",
          "Arc A 01-02-1080p-03.mkv",
          "Arc A 01-02.03.mkv",
          "Arc A 01-02+03.mkv",
          "Arc A 01-02,03.mkv",
          "Arc A 01-02 WEB,03.mkv",
          "Arc A 01-02 WEB 03.mkv",
          "Arc A 01-02−03.mkv"
        ] do
      chained_fixture =
        put_in(safe_fixture, ["inventory", Access.at(0), "relative_path"], relative_path)

      assert {:needs_mapping, chained_result} = run_fixture(chained_fixture)
      assert chained_result.issue["reason"] == "unresolved_file"
    end

    uuid_fixture =
      put_in(
        safe_fixture,
        ["inventory", Access.at(0), "relative_path"],
        "Arc A 01-02.cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv"
      )

    assert {:ok, %{assignments: [%{episode_ids: [1, 2]}]}} = run_fixture(uuid_fixture)

    malicious_mapping = %{
      "identity" => %{
        "source" => "tmdb",
        "scheme" => "scene",
        "namespace" => "author-order",
        "canonical_value" => "S11E03"
      },
      "precedence" => "inferred",
      "scope_title" => "Arc B",
      "episode_ids" => [3],
      "evidence" => nil
    }

    malicious_fixture =
      safe_fixture
      |> update_in(["mappings"], &(&1 ++ [malicious_mapping]))
      |> update_in(
        ["episodes"],
        &(&1 ++ [%{"id" => 3, "season_number" => 0, "episode_number" => 3}])
      )
      |> put_in(
        ["inventory", Access.at(0), "relative_path"],
        "Arc A 01-02-S11E03.mkv"
      )

    assert {:needs_mapping, malicious_result} = run_fixture(malicious_fixture)
    assert malicious_result.issue["reason"] == "invalid_snapshot"
  end

  # A batch of 10 files named with TVDB/scene-style "S02Enn" coordinates, resolvable only via a
  # persisted `scheme: "scene"` mapping (source "tmdb", precedence :inferred) — the alternate
  # numbering an operator-chosen TMDB episode group synced onto the series (A6). Cinder's own
  # episodes 29-38 (TMDB season 1) are the reserved set.
  defp frieren_scene_fixture(episode_range) do
    %{
      "snapshot_version" => 2,
      "parser_context" => %{"title" => "Frieren", "aliases" => [], "year" => 2023},
      "mappings" =>
        for n <- episode_range do
          %{
            "identity" => %{
              "source" => "tmdb",
              "scheme" => "scene",
              "namespace" => "seasons-group",
              "canonical_value" => Episode.code(2, n)
            },
            "precedence" => "inferred",
            "episode_ids" => [n + 28],
            "evidence" => nil
          }
        end,
      "inventory" =>
        for n <- episode_range do
          %{
            "relative_path" => "Frieren - #{Episode.code(2, n)}.mkv",
            "size" => 1000,
            "major_device" => 1,
            "inode" => 200 + n,
            "mtime" => 100
          }
        end,
      "episodes" =>
        for(n <- 29..38, do: %{"id" => n, "season_number" => 1, "episode_number" => n})
    }
  end

  defp snapshot_from_fixture(fixture) do
    reserved_ids =
      fixture["reserved_episode_ids"] || Enum.map(fixture["episodes"], & &1["id"])

    parser_context = fixture["parser_context"]
    legacy_context? = Map.keys(parser_context) |> Enum.sort() == ["aliases", "title", "year"]
    version = if fixture["snapshot_version"] == 2 and legacy_context?, do: 2, else: 3

    parser_context =
      if version == 3 do
        parser_context
        |> maybe_add_v3_blocked_titles(fixture["snapshot_version"])
        |> Map.put_new("allow_unscoped_standard", false)
      else
        parser_context
      end

    {mappings, selected_mappings} =
      mappings_with_reservation_authority(fixture["mappings"], reserved_ids)

    selected_values = Enum.map(selected_mappings, &selected_value/1)

    %{
      "version" => version,
      "parser_context" => parser_context,
      "mappings" => mappings,
      "reserved_episode_ids" => reserved_ids,
      "release" => %{
        "coordinates" => Enum.map(selected_values, &selected_coordinate/1)
      },
      "selected_resolution" => %{
        "episode_ids" => reserved_ids,
        "values" => selected_values
      }
    }
  end

  defp maybe_add_v3_blocked_titles(context, 2), do: Map.put_new(context, "blocked_titles", [])
  defp maybe_add_v3_blocked_titles(context, _version), do: context

  defp mappings_with_reservation_authority(mappings, reserved_ids) do
    {mappings, selected} =
      Enum.reduce(reserved_ids, {mappings, []}, fn episode_id, {all, selected} ->
        mapping =
          Enum.find(all, &(&1["episode_ids"] == [episode_id])) || reservation_mapping(episode_id)

        all = if mapping in all, do: all, else: all ++ [mapping]
        {all, selected ++ [mapping]}
      end)

    {mappings, selected}
  end

  defp reservation_mapping(episode_id) do
    %{
      "identity" => %{
        "source" => "fixture",
        "scheme" => "reservation",
        "namespace" => "canonical",
        "canonical_value" => "episode-#{episode_id}"
      },
      "precedence" => "curated",
      "episode_ids" => [episode_id],
      "evidence" => nil
    }
  end

  defp selected_value(mapping) do
    identity = mapping["identity"]

    %{
      "scheme" => identity["scheme"],
      "canonical_value" => identity["canonical_value"],
      "episode_ids" => mapping["episode_ids"],
      "precedence" => mapping["precedence"],
      "mapping_identities" => [identity]
    }
    |> maybe_put_selected_scope(mapping)
  end

  defp selected_coordinate(value) do
    %{"scheme" => value["scheme"], "values" => [value["canonical_value"]]}
    |> maybe_put_selected_scope(value)
  end

  defp maybe_put_selected_scope(value, %{"scope_title" => title, "identity" => identity}) do
    Map.merge(value, %{
      "source" => identity["source"],
      "namespace" => identity["namespace"],
      "scope_title" => TitleAlias.normalize(title)
    })
  end

  defp maybe_put_selected_scope(value, %{"scope_title" => title} = source) do
    Map.merge(value, %{
      "source" => source["source"],
      "namespace" => source["namespace"],
      "scope_title" => TitleAlias.normalize(title)
    })
  end

  defp maybe_put_selected_scope(value, _source), do: value

  defp run_fixture(fixture) do
    snapshot = snapshot_from_fixture(fixture)

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
