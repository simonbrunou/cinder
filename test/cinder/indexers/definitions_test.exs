defmodule Cinder.Indexers.DefinitionsTest do
  # One test attaches a global telemetry handler on the repo's queries.
  use Cinder.DataCase, async: false

  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Copy, Entry, Loader, LoadResult, Set, StoredSet}
  alias Cinder.Indexers.Definitions.Set.{DefinitionFile, Versions}

  @commit_a String.duplicate("a", 40)
  @commit_b String.duplicate("b", 40)
  @commit_c String.duplicate("c", 40)

  # A definition written for Cinder's tests, as LoadCheckTest's @base, with its own id.
  defp yaml(id, extra \\ %{}) do
    %{
      "id" => id,
      "name" => "Cinder Test #{id}",
      "description" => "Written for Cinder's tests: #{id}",
      "language" => "en-US",
      "type" => "public",
      "encoding" => "UTF-8",
      "links" => ["https://tracker.invalid/"],
      "settings" => [],
      "caps" => %{"modes" => %{"search" => ["q"]}},
      "search" => %{
        "rows" => %{"selector" => "tr"},
        "fields" => %{"title" => %{"selector" => "a"}}
      }
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp blob_sha(bytes),
    do: :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)

  defp file(folder, name, bytes),
    do: %DefinitionFile{folder: folder, name: name, blob_sha: blob_sha(bytes), bytes: bytes}

  # A file whose bytes depend only on its name, so the same name in two folders shares a blob.
  defp file(folder, name), do: file(folder, name, yaml(Path.rootname(name)))

  defp answer(commit, files, opts \\ []) do
    min = Keyword.get(opts, :min, 11)
    max = Keyword.get(opts, :max, 12)

    %Set{
      commit: commit,
      versions: %Versions{
        min: min,
        max: max,
        values: %{"MIN_VERSION" => "#{min}", "MAX_VERSION" => "#{max}"}
      },
      files: files
    }
  end

  # `count` distinct v11 names, `prefix-1.yml` and up.
  defp names(count, prefix \\ "n"),
    do: for(i <- 1..count//1, do: file("v11", "#{prefix}-#{i}.yml"))

  # The pure loader, reporting each call to the test: no worker, so the big sets stay fast.
  defp counting_check do
    test_pid = self()

    fn bytes ->
      send(test_pid, {:checked, bytes})
      Loader.load(bytes)
    end
  end

  defp apply_counting(set), do: Definitions.apply_set(set, check: counting_check())

  defp checked do
    receive do
      {:checked, bytes} -> [bytes | checked()]
    after
      0 -> []
    end
  end

  defp snapshot do
    %{
      copies: Repo.all(from(c in Copy, order_by: c.id)),
      results: Repo.all(from(r in LoadResult, order_by: r.id)),
      entries: Repo.all(from(e in Entry, order_by: e.id)),
      set:
        StoredSet
        |> Repo.get(1)
        |> Map.take([:commit, :versions, :count, :loaded_at, :accepted_commit])
    }
  end

  defp entry(name), do: Repo.get_by!(Entry, name: name)

  describe "apply_set/2: the 100-name floor and the 90% line" do
    test "a first answer of 100 names loads and one of 99 is refused" do
      assert {:error, {:first_too_small, %{commit: @commit_a, count: 99}}} =
               apply_counting(answer(@commit_a, names(99)))

      assert Definitions.set_state() ==
               {:first_too_small, %{commit: @commit_a, count: 99, loaded: nil}}

      assert Definitions.name_status("n-1.yml") == :never_loaded

      assert Repo.aggregate(Entry, :count) == 0
      assert checked() == []

      assert {:ok, {:loaded, %{count: 100, commit: @commit_b}}} =
               apply_counting(answer(@commit_b, names(100)))

      assert Repo.aggregate(Entry, :count) == 100
    end

    test "with a stored set of 200, 180 names apply and 179 read shrank by 10%" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(200)))

      assert {:ok, {:loaded, %{count: 180, commit: @commit_b}}} =
               apply_counting(answer(@commit_b, names(180)))

      # The next answer compares with 180 now: 162 is exactly 90% of it.
      {:ok, _state} = apply_counting(answer(@commit_a, names(200)))

      assert {:error, {:shrank, %{percent: 10, commit: @commit_c, count: 179}}} =
               apply_counting(answer(@commit_c, names(179)))

      assert {:shrank,
              %{
                percent: 10,
                commit: @commit_c,
                count: 179,
                loaded: %{commit: @commit_a, count: 200}
              }} =
               Definitions.set_state()
    end

    test "the shrink percent is rounded down" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(200)))

      # 200 to 150 is 25%, 200 to 151 is 24.5%.
      assert {:error, {:shrank, %{percent: 24}}} = apply_counting(answer(@commit_b, names(151)))
      assert {:error, {:shrank, %{percent: 25}}} = apply_counting(answer(@commit_b, names(150)))
    end

    test "a refusal keeps every stored row" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(200)))
      before = snapshot()

      for refused <- [names(179), names(1)] do
        assert {:error, {:shrank, _}} = apply_counting(answer(@commit_b, refused))
        assert snapshot() == before
      end

      assert {:error, {:cinder_too_old, _}} =
               apply_counting(answer(@commit_b, names(200, "m"), min: 13))

      assert snapshot() == before
    end

    test "the guard counts distinct names across every folder from MIN_VERSION up, not the mirror" do
      # 90 names in v11, the same 90 in v12, 10 only in v13, and 50 in v10 below MIN_VERSION:
      # 100 names count, of which 90 enter the mirror.
      files =
        names(90) ++
          Enum.map(names(90), &%{&1 | folder: "v12"}) ++
          Enum.map(names(10, "up"), &%{&1 | folder: "v13"}) ++
          Enum.map(names(50, "low"), &%{&1 | folder: "v10"})

      assert {:ok, {:loaded, %{count: 100}}} = apply_counting(answer(@commit_a, files))
      assert Repo.aggregate(from(e in Entry, where: not is_nil(e.blob_sha)), :count) == 90
      assert {:loaded, %{count: 100}} = Definitions.set_state()
    end
  end

  describe "accept_smaller_set/1" do
    test "the accepted commit applies at the next apply, for a shrunk answer" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(200)))
      assert {:error, {:shrank, _}} = apply_counting(answer(@commit_b, names(150)))

      assert :ok = Definitions.accept_smaller_set(@commit_b)
      assert {:ok, {:loaded, %{count: 150}}} = apply_counting(answer(@commit_b, names(150)))
    end

    test "the accepted commit applies at the next apply, for a first answer of 99 names" do
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))

      assert :ok = Definitions.accept_smaller_set(@commit_a)
      assert {:ok, {:loaded, %{count: 99}}} = apply_counting(answer(@commit_a, names(99)))
    end

    test "an answer at another commit is still refused" do
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))
      assert :ok = Definitions.accept_smaller_set(@commit_a)

      assert {:error, {:first_too_small, %{commit: @commit_b}}} =
               apply_counting(answer(@commit_b, names(99)))
    end

    test "takes only the commit of the refusal the set state holds" do
      assert {:error, :not_refused} = Definitions.accept_smaller_set(@commit_a)

      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))
      assert {:error, :not_refused} = Definitions.accept_smaller_set(@commit_b)
      assert Repo.get!(StoredSet, 1).accepted_commit == nil

      {:ok, _state} = apply_counting(answer(@commit_c, names(100)))
      assert {:error, :not_refused} = Definitions.accept_smaller_set(@commit_c)

      assert {:error, {:cinder_too_old, _}} =
               apply_counting(answer(@commit_b, names(100), min: 13))

      assert {:error, :not_refused} = Definitions.accept_smaller_set(@commit_b)
    end

    test "a refusal at another commit drops the acceptance" do
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))
      :ok = Definitions.accept_smaller_set(@commit_a)
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_b, names(99)))

      assert Repo.get!(StoredSet, 1).accepted_commit == nil
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))
    end

    test "a successful apply clears the accepted commit" do
      assert {:error, {:first_too_small, _}} = apply_counting(answer(@commit_a, names(99)))
      :ok = Definitions.accept_smaller_set(@commit_a)
      {:ok, _state} = apply_counting(answer(@commit_a, names(99)))

      assert Repo.get!(StoredSet, 1).accepted_commit == nil
    end
  end

  describe "apply_set/2: folders" do
    test "MIN_VERSION 13 with engine 12 reads Cinder too old and keeps the set" do
      assert Definitions.engine_version() == 12
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      before = snapshot()

      assert {:error, {:cinder_too_old, %{commit: @commit_b, min_version: 13}}} =
               apply_counting(answer(@commit_b, names(100, "m"), min: 13))

      assert {:cinder_too_old,
              %{commit: @commit_b, min_version: 13, loaded: %{commit: @commit_a, count: 100}}} =
               Definitions.set_state()

      assert snapshot() == before
      assert checked() |> length() == 100
    end

    test "a MIN_VERSION past SQLite's integer reads Cinder too old with its value" do
      huge = String.duplicate("9", 30)
      set = answer(@commit_a, names(100), min: String.to_integer(huge))

      assert {:error, {:cinder_too_old, %{min_version: min, loaded: nil}}} = apply_counting(set)
      assert Integer.to_string(min) == huge
      assert {:cinder_too_old, %{min_version: ^min}} = Definitions.set_state()
    end

    test "MIN_VERSION 12 with engine 12 applies" do
      files = Enum.map(names(100), &%{&1 | folder: "v12"})
      assert {:ok, {:loaded, _}} = apply_counting(answer(@commit_a, files, min: 12))
    end

    test "with MAX_VERSION=11 and a file in v13, the v13 folder is still recorded" do
      files = names(100) ++ [file("v13", "n-1.yml", yaml("n-1-v13")), file("v13", "only.yml")]

      {:ok, _state} = apply_counting(answer(@commit_a, files, max: 11))

      assert %{folder: 11, newer_folder: 13} = entry("n-1.yml")
      assert Definitions.name_status("only.yml") == {:needs_newer_cinder, 13}
    end

    test "a name with a different copy in v13 records folder 13, and one with the same copy none" do
      files =
        names(100) ++
          [
            file("v13", "n-1.yml", yaml("n-1-v13")),
            file("v14", "n-1.yml", yaml("n-1-v14")),
            file("v13", "n-2.yml")
          ]

      {:ok, _state} = apply_counting(answer(@commit_a, files))

      assert %{folder: 11, newer_folder: 14} = entry("n-1.yml")
      assert %{folder: 11, newer_folder: nil} = entry("n-2.yml")
      refute Repo.exists?(from(c in Copy, where: c.folder > 12))
    end

    test "a name only in v13 reads needs a newer Cinder (v13), and leaves the picker" do
      files = names(100) ++ [file("v14", "only.yml"), file("v13", "only.yml", yaml("only-13"))]
      {:ok, _state} = apply_counting(answer(@commit_a, files))

      assert Definitions.name_status("only.yml") == {:needs_newer_cinder, 13}
      assert %{blob_sha: nil, folder: nil} = entry("only.yml")
      refute Enum.any?(Definitions.picker(), &(&1.name == "only.yml"))
    end

    test "the copy in v12 wins over v11" do
      v12 = file("v12", "n-1.yml", yaml("n-1-v12"))
      {:ok, _state} = apply_counting(answer(@commit_a, names(100) ++ [v12]))

      assert %{folder: 12, blob_sha: sha} = entry("n-1.yml")
      assert sha == v12.blob_sha
      assert %{id: "n-1-v12"} = Enum.find(Definitions.picker(), &(&1.name == "n-1.yml"))
    end

    test "folders below MIN_VERSION are not read" do
      low = file("v11", "n-1.yml", yaml("n-1-v11"))
      files = Enum.map(names(100), &%{&1 | folder: "v12"}) ++ [low, file("v11", "low.yml")]

      {:ok, {:loaded, %{count: 100}}} = apply_counting(answer(@commit_a, files, min: 12))

      assert %{folder: 12} = entry("n-1.yml")
      refute Repo.exists?(from(c in Copy, where: c.blob_sha == ^low.blob_sha))
      assert Definitions.name_status("low.yml") == :removed_upstream
    end

    test "a folder spelled with a leading zero or past six digits is not read" do
      odd = [
        file("v011", "n-1.yml", yaml("zero")),
        file("v0012", "zero.yml"),
        file("v1000000", "huge.yml")
      ]

      {:ok, {:loaded, %{count: 100}}} = apply_counting(answer(@commit_a, names(100) ++ odd))

      assert %{folder: 11, newer_folder: nil} = entry("n-1.yml")
      assert Definitions.name_status("zero.yml") == :removed_upstream
      assert Definitions.name_status("huge.yml") == :removed_upstream
    end

    test "a folder of six digits is read" do
      {:ok, _state} =
        apply_counting(answer(@commit_a, names(100) ++ [file("v999999", "big.yml")]))

      assert Definitions.name_status("big.yml") == {:needs_newer_cinder, 999_999}
    end
  end

  describe "apply_set/2: load checks" do
    test "run once per blob hash, never inside the transaction, and none on a second apply" do
      test_pid = self()
      handler = "definitions-test-#{inspect(self())}"

      :telemetry.attach(
        handler,
        [:cinder, :repo, :query],
        fn _event, _measures, %{query: query}, _config -> send(test_pid, {:query, query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # n-1.yml is the same bytes in v11 and v12; a.yml and b.yml share one blob in v11.
      shared = yaml("shared")

      files =
        names(100) ++
          [file("v12", "n-1.yml"), file("v11", "a.yml", shared), file("v11", "b.yml", shared)]

      {:ok, _state} = apply_counting(answer(@commit_a, files))

      events = collect_events()
      checks = Enum.filter(events, &match?({:checked, _}, &1))
      assert length(checks) == 101
      assert length(Enum.uniq(checks)) == 101

      first_write = Enum.find_index(events, &transaction_start?/1)
      last_check = events |> Enum.with_index() |> Enum.filter(&match?({{:checked, _}, _}, &1))
      assert first_write
      assert Enum.all?(last_check, fn {_check, index} -> index < first_write end)

      {:ok, _state} = apply_counting(answer(@commit_b, files))
      assert checked() == []
    end

    test "run at most ParserWorker.max_check_workers() at a time" do
      test_pid = self()

      check = fn bytes ->
        send(test_pid, {:started, self()})

        receive do
          :go -> Loader.load(bytes)
        end
      end

      copies = for i <- 1..5, do: %{blob_sha: "sha#{i}", bytes: yaml("c#{i}")}
      task = Task.async(fn -> Definitions.check_copies(copies, check: check) end)

      assert_receive {:started, first}
      assert_receive {:started, second}
      refute_receive {:started, _third}, 200

      send(first, :go)
      assert_receive {:started, third}
      refute_receive {:started, _fourth}, 200

      for pid <- [second, third], do: send(pid, :go)
      assert_receive {:started, fourth}
      assert_receive {:started, fifth}
      for pid <- [fourth, fifth], do: send(pid, :go)

      assert task |> Task.await() |> length() == 5
    end

    test "a check past its timeout has no answer; the timeout is 5 minutes" do
      assert Definitions.check_timeout_ms() == 300_000

      hung = yaml("hung")

      check = fn
        ^hung ->
          receive do
            :never -> :ok
          end

        bytes ->
          Loader.load(bytes)
      end

      # Only the hung check runs under the shrunk deadline; the one meant to finish gets 10 s of
      # headroom for a loaded host (testing.md, #1118).
      {answers, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Definitions.check_copies([%{blob_sha: "hung", bytes: hung}],
            check: check,
            timeout_ms: 500
          )
        end)

      assert answers == []
      assert log =~ "indexer definition load check timed out: blob hung"

      assert [{"ok", {:ok, _definition}}] =
               Definitions.check_copies([%{blob_sha: "ok", bytes: yaml("ok")}],
                 check: check,
                 timeout_ms: 10_000
               )
    end

    test "a check that raises stores no result for its blob, and the rest applies" do
      broken = yaml("broken")

      check = fn
        ^broken -> raise "boom"
        bytes -> Loader.load(bytes)
      end

      files = names(100) ++ [file("v11", "broken.yml", broken)]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:loaded, %{count: 101}}} =
                   Definitions.apply_set(answer(@commit_a, files), check: check)
        end)

      assert log =~ "indexer definition load check raised"
      assert %{result: :unchecked} = Enum.find(Definitions.picker(), &(&1.name == "broken.yml"))
      assert [%{blob_sha: sha}] = Definitions.stale_copies()
      assert sha == blob_sha(broken)
    end

    test "the default check is LoadCheck's, selector codes included" do
      # A comment in a selector is a code of the selector gate, which Loader.load/1 never adds.
      odd =
        yaml("odd", %{
          "search" => %{
            "rows" => %{"selector" => "tr /* x */"},
            "fields" => %{"title" => %{"selector" => "a"}}
          }
        })

      # Three files: the first answer is refused before any check, and accepted.
      files = names(2, "d") ++ [file("v11", "odd.yml", odd)]
      assert {:error, {:first_too_small, _}} = Definitions.apply_set(answer(@commit_a, files))
      :ok = Definitions.accept_smaller_set(@commit_a)
      assert {:ok, _state} = Definitions.apply_set(answer(@commit_a, files))

      assert %{result: {:not_supported, codes}} =
               Enum.find(Definitions.picker(), &(&1.name == "odd.yml"))

      assert {:selector, :comment} in codes
    end
  end

  defp collect_events do
    receive do
      {:checked, _bytes} = event -> [event | collect_events()]
      {:query, _query} = event -> [event | collect_events()]
    after
      0 -> []
    end
  end

  defp transaction_start?({:query, query}),
    do: query |> String.downcase() |> String.starts_with?(["begin", "savepoint"])

  defp transaction_start?(_event), do: false

  describe "the boot re-check" do
    test "lists copies with results under an older fingerprint only, and stores their new results" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      assert length(checked()) == 100
      assert Definitions.stale_copies() == []

      %{schema_version: version, revision: revision} = Loader.fingerprint()
      stale = Enum.map(["n-1.yml", "n-2.yml"], &entry(&1).blob_sha)

      # n-1's result came from an older revision, n-2's from an older schema version.
      Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^Enum.at(stale, 0)),
        set: [revision: revision - 1]
      )

      Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^Enum.at(stale, 1)),
        set: [schema_version: version - 1]
      )

      copies = Definitions.stale_copies()
      assert Enum.sort(Enum.map(copies, & &1.blob_sha)) == Enum.sort(stale)

      unchecked = for %{result: :unchecked, name: name} <- Definitions.picker(), do: name
      assert unchecked == ["n-1.yml", "n-2.yml"]

      results = Definitions.check_copies(copies, check: counting_check())
      assert length(checked()) == 2
      assert :ok = Definitions.store_results(results)

      assert Definitions.stale_copies() == []

      assert Repo.aggregate(
               from(r in LoadResult,
                 where: r.schema_version == ^version and r.revision == ^revision
               ),
               :count
             ) == 100
    end

    test "apply_set/2 checks again the copies whose results an older fingerprint wrote" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      assert length(checked()) == 100

      %{schema_version: version, revision: revision} = Loader.fingerprint()
      [one, two] = Enum.map(["n-1.yml", "n-2.yml"], &entry(&1).blob_sha)

      Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^one),
        set: [revision: revision - 1]
      )

      Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^two),
        set: [schema_version: version - 1]
      )

      {:ok, _state} = apply_counting(answer(@commit_b, names(100)))

      assert Enum.sort(checked()) == Enum.sort([yaml("n-1"), yaml("n-2")])
      assert Definitions.stale_copies() == []
      refute Enum.any?(Definitions.picker(), &(&1.result == :unchecked))
    end

    test "store_results/1 sets the entries' replaces from the new answer" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      sha = entry("n-1.yml").blob_sha
      Repo.delete_all(from(r in LoadResult, where: r.blob_sha == ^sha))

      :ok =
        Definitions.store_results([
          {sha, {:ok, %{elem(Loader.load(yaml("n-1")), 1) | replaces: ["old"]}}}
        ])

      assert entry("n-1.yml").replaces == ["old"]
      assert Definitions.name_status("old.yml") == {:replaced_by, "n-1.yml"}
    end

    test "store_results/1 drops a result for a blob no copy holds" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      gone = yaml("gone")

      :ok = Definitions.store_results([{blob_sha(gone), Loader.load(gone)}])

      refute Repo.exists?(from(r in LoadResult, where: r.blob_sha == ^blob_sha(gone)))
    end
  end

  describe "removals per name" do
    test "removed upstream, replaced by, back in the mirror, and the picker" do
      replacer = file("v11", "new.yml", yaml("new", %{"replaces" => ["old", "other"]}))
      {:ok, _state} = apply_counting(answer(@commit_a, names(100) ++ [file("v11", "old.yml")]))

      assert Definitions.name_status("old.yml") == :in_mirror
      assert Enum.any?(Definitions.picker(), &(&1.name == "old.yml"))

      {:ok, _state} = apply_counting(answer(@commit_b, names(100) ++ [replacer]))
      assert Definitions.name_status("old.yml") == {:replaced_by, "new.yml"}
      assert Definitions.name_status("n-1.yml") == :in_mirror
      refute Enum.any?(Definitions.picker(), &(&1.name == "old.yml"))

      {:ok, _state} = apply_counting(answer(@commit_c, names(100)))
      assert Definitions.name_status("old.yml") == :removed_upstream
      assert Definitions.name_status("new.yml") == :removed_upstream

      {:ok, _state} = apply_counting(answer(@commit_a, names(100) ++ [file("v11", "old.yml")]))
      assert Definitions.name_status("old.yml") == :in_mirror
      assert Enum.any?(Definitions.picker(), &(&1.name == "old.yml"))
    end

    test "a name before any load, and a name two mirror copies replace" do
      assert Definitions.name_status("n-1.yml") == :never_loaded

      replacers = [
        file("v11", "z.yml", yaml("z", %{"replaces" => ["old"]})),
        file("v11", "y.yml", yaml("y", %{"replaces" => ["old"]}))
      ]

      {:ok, _state} = apply_counting(answer(@commit_a, names(100) ++ replacers))
      assert Definitions.name_status("old.yml") == {:replaced_by, "y.yml"}
    end

    test "the picker returns each mirror name with its display fields and load result" do
      {:ok, _state} =
        apply_counting(answer(@commit_a, names(99) ++ [file("v11", "bad.yml", "id: [unclosed")]))

      picker = Definitions.picker()
      assert length(picker) == 100
      assert Enum.map(picker, & &1.name) == Enum.sort(Enum.map(picker, & &1.name))

      assert %{
               id: "n-1",
               privacy: "public",
               language: "en-US",
               description: "Written for Cinder's tests: n-1",
               result: :loads
             } = Enum.find(picker, &(&1.name == "n-1.yml"))

      assert %{id: nil, privacy: nil, result: {:fails, {:yaml_syntax, _}}} =
               Enum.find(picker, &(&1.name == "bad.yml"))
    end
  end

  describe "deleting what nothing uses" do
    test "the next apply deletes the copies and results no entry uses and keeps the rest" do
      {:ok, _state} = apply_counting(answer(@commit_a, names(100) ++ [file("v11", "old.yml")]))
      old = entry("old.yml").blob_sha
      kept = entry("n-1.yml").blob_sha

      %{schema_version: version, revision: revision} = Loader.fingerprint()

      # Results an older and a newer build wrote, on either side of the current one.
      for other <- [revision - 1, revision + 1] do
        Repo.insert!(%LoadResult{
          blob_sha: kept,
          schema_version: version,
          revision: other,
          outcome: :loads,
          replaces: ["ghost"]
        })
      end

      {:ok, _state} = apply_counting(answer(@commit_b, names(100)))

      # The entry's replaces come from the current result, never another fingerprint's.
      assert entry("n-1.yml").replaces == []
      assert Definitions.name_status("ghost.yml") == :removed_upstream

      refute Repo.exists?(from(c in Copy, where: c.blob_sha == ^old))
      refute Repo.exists?(from(r in LoadResult, where: r.blob_sha == ^old))
      assert Repo.exists?(from(c in Copy, where: c.blob_sha == ^kept))

      assert [%{revision: ^revision}] =
               Repo.all(from(r in LoadResult, where: r.blob_sha == ^kept))

      assert Repo.aggregate(Copy, :count) == 100
      assert Repo.aggregate(LoadResult, :count) == 100
    end
  end

  describe "copy rows" do
    test "a copy kept under another file name takes the new name" do
      shared = yaml("shared")

      {:ok, _state} =
        apply_counting(answer(@commit_a, names(100) ++ [file("v11", "a.yml", shared)]))

      {:ok, _state} =
        apply_counting(answer(@commit_b, names(100) ++ [file("v11", "b.yml", shared)]))

      assert [%{name: "b.yml"}] =
               Repo.all(from(c in Copy, where: c.blob_sha == ^blob_sha(shared)))
    end
  end

  describe "set_state/0" do
    test "never loaded before the first apply; loaded with count, commit and time after it" do
      assert Definitions.set_state() == :never_loaded

      before = DateTime.utc_now(:second)
      {:ok, _state} = apply_counting(answer(@commit_a, names(100)))
      after_apply = DateTime.utc_now(:second)

      assert {:loaded, %{count: 100, commit: @commit_a, loaded_at: loaded_at}} =
               Definitions.set_state()

      assert DateTime.compare(loaded_at, before) != :lt
      assert DateTime.compare(loaded_at, after_apply) != :gt

      assert Repo.get!(StoredSet, 1).versions == %{"MIN_VERSION" => "11", "MAX_VERSION" => "12"}
    end
  end
end
