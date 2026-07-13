# A3 Safe Import Mapping Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate A2 episodic-anime acquisition with an immutable reservation snapshot, deterministic file-to-stable-episode preflight, atomic multi-season import, and an admin recovery page for every ambiguous or stale mapping.

**Architecture:** Keep the standard TV search and import branch unchanged. Snapshot-bearing grabs take a separate anime branch: the Download intent becomes a grab atomically, Library inventories and resolves files without side effects, Catalog persists that evidence before ImportStage runs, and any ambiguity becomes a durable `:needs_mapping` state. Recovery changes only current episode ownership and explicit override evidence; the original snapshot remains immutable.

**Tech Stack:** Elixir, Phoenix 1.8 LiveView, Ecto with SQLite, ExUnit/Mox, Jason fixtures, the existing `AnimeParser`, `AnimeResolver`, `ImportStage`, `PathPolicy`, and the repository's `mix test` quality alias.

## Global Constraints

- Work only on roadmap phase A3. Do not implement specials acquisition, anime preferences, provider discovery, or the A4 fallback UX.
- Preserve the standard `Acquisition.best_releases/4` and `Library.stage_episodes/2` paths byte-for-byte except for routing around them.
- A snapshot is immutable reservation evidence. Current `grab.episodes` links are authoritative after recovery; `manual_mapping_overrides` explains any difference.
- Version 2 snapshots freeze parser title, at most seven aliases, and year. Version 1 snapshots remain valid input but cannot be automatically reparsed; they must enter `:needs_mapping`.
- Never persist or render absolute source paths. Persist only relative paths plus `size`, `major_device`, `inode`, and `mtime` identity values.
- Before any ImportStage write, persist automatic decisions or a mapping issue. Re-inventory immediately before staging and stop if identity changed.
- A file may satisfy many episode IDs. An episode ID may belong to only one file. Every authoritative ID must be assigned exactly once, and every video must be assigned or explicitly ignored with parser evidence or an admin-owned manual decision.
- Recovery additions must belong to the same series and be missing/unowned. Unmonitored additions require an explicit monitor opt-in. Removed targets become wanted again without incrementing search attempts.
- Every database write goes through Catalog. Filesystem work stays in Library. Pure mapping logic performs no Repo, filesystem, network, or LiveView work.
- External services remain behind existing behaviours; tests never use a network service.
- Every production behavior change follows red-green-refactor: run the focused test and observe the specified failure before implementation.
- Add no dependency, framework, setting, column unrelated to the five mapping fields, or speculative abstraction.
- Run `mix format` before every commit. Run `graphify update .` after all code changes. `mix test` is the final source of truth.

---

### Task 1: Freeze parser context in version 2 reservation snapshots

**Files:**
- Modify: `lib/cinder/acquisition/anime.ex:83-111`
- Modify: `lib/cinder/download/intent.ex:62-155`
- Modify: `test/cinder/acquisition/anime_selection_test.exs`
- Modify: `test/cinder/download/intent_test.exs`

**Interfaces:**
- Produces: `Anime.build_mapping_snapshot/3` version 2 documents with `parser_context`.
- Accepts: both version 1 and version 2 documents in `Intent.reservation_changeset/2`.
- Preserves: exact validation of reserved IDs, release coordinates, mapping coverage, and selected resolution.

- [ ] **Step 1: Write failing snapshot and validator tests**

Extend the acquisition test to assert the complete frozen parser input:

```elixir
assert snapshot["version"] == 2

assert snapshot["parser_context"] == %{
         "title" => "Frieren: Beyond Journey's End",
         "aliases" => ["Sousou no Frieren", "葬送のフリーレン"],
         "year" => 2023
       }
```

Add Intent tests proving version 1 is still accepted, version 2 with that context is accepted, and these mutations are rejected independently:

```elixir
for invalid_context <- [
      nil,
      %{},
      %{"title" => "", "aliases" => [], "year" => 2023},
      %{"title" => "Frieren", "aliases" => [42], "year" => 2023},
      %{"title" => "Frieren", "aliases" => List.duplicate("alias", 8), "year" => 2023},
      %{"title" => "Frieren", "aliases" => [], "year" => "2023"}
    ] do
  attrs = valid_attrs(mapping_snapshot: put_in(snapshot["parser_context"], invalid_context))
  refute Intent.reservation_changeset(%Intent{}, attrs).valid?
end
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `mix test test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs`

Expected: the producer still emits version 1 without `parser_context`, and Intent rejects version 2.

- [ ] **Step 3: Emit version 2 and validate versions explicitly**

Change the snapshot header in `Anime.build_mapping_snapshot/3`:

```elixir
%{
  "version" => 2,
  "parser_context" => %{
    "title" => context.title,
    "aliases" => context.aliases |> Enum.map(& &1.title) |> Enum.take(@max_aliases),
    "year" => context.year
  },
  "reserved_episode_ids" => reserved_ids,
  "release" => %{
    "title" => release.title,
    "coordinates" => Enum.map(release.coordinates || [], &snapshot_coordinate/1),
    "group" => release.group,
    "category_ids" => release.category_ids || [],
    "indexer_id" => release.indexer_id,
    "published_at" => iso8601(release.published_at)
  },
  "mappings" => mappings,
  "selected_resolution" => %{
    "episode_ids" => reserved_ids,
    "values" => Enum.map(release.resolution_evidence || [], &snapshot_resolution/1)
  }
}
```

Keep the existing `snapshot_coordinate/1`, `snapshot_resolution/1`, and `iso8601/1` helpers. In Intent, match the common document first and delegate only version validation:

```elixir
with %{
       "reserved_episode_ids" => reserved_ids,
       "release" => release,
       "mappings" => mappings,
       "selected_resolution" => selected
     } <- snapshot,
     true <- valid_snapshot_version?(snapshot),
     true <- valid_episode_ids?(reserved_ids),
     true <- reserved_ids == intent_episode_ids,
     true <- valid_release?(release),
     {:ok, mapping_index} <- mapping_index(mappings, reserved_ids),
     true <- mappings_cover?(mappings, reserved_ids),
     true <- valid_selected_resolution?(selected, release, mapping_index, reserved_ids) do
  true
else
  _invalid -> false
end
```

Add bounded version validation:

```elixir
defp valid_snapshot_version?(%{"version" => 1}), do: true

defp valid_snapshot_version?(%{
       "version" => 2,
       "parser_context" => %{"title" => title, "aliases" => aliases, "year" => year}
     }) do
  nonempty_string?(title) and is_list(aliases) and length(aliases) <= 7 and
    Enum.all?(aliases, &nonempty_string?/1) and (is_nil(year) or is_integer(year))
end

defp valid_snapshot_version?(_snapshot), do: false
```

- [ ] **Step 4: Verify GREEN and format**

Run: `mix format && mix test test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs`

Expected: both files pass, including all A2 immutability and malformed-document cases.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/anime.ex lib/cinder/download/intent.ex test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs
git commit -m "feat: freeze anime parser context"
```

### Task 2: Add durable grab mapping state and atomic intent transfer

**Files:**
- Create: `priv/repo/migrations/*_add_anime_mapping_state_to_grabs.exs` via `mix ecto.gen.migration add_anime_mapping_state_to_grabs`
- Modify: `lib/cinder/catalog/grab.ex`
- Modify: `lib/cinder/catalog.ex:1602-1668`
- Modify: `lib/cinder/download.ex:215-285`
- Create: `test/cinder/catalog/grab_mapping_test.exs`
- Modify: `test/cinder/download/intent_test.exs`

**Interfaces:**
- Adds: `mapping_snapshot`, `mapping_status`, `automatic_mapping_decisions`, `manual_mapping_overrides`, and `mapping_issue` to `Cinder.Catalog.Grab`.
- Produces: `Catalog.create_grab_from_intent/1` for the exact intent-to-grab ownership transfer.
- Keeps: the A2 `:anime_import_not_ready` guards until Task 6, so storage work cannot activate unsafe downloading.

- [ ] **Step 1: Generate the migration and write failing schema/transaction tests**

Run: `mix ecto.gen.migration add_anime_mapping_state_to_grabs`

Add tests for these cases:

```elixir
test "create_grab_from_intent atomically copies the snapshot, links every reserved episode, and deletes the intent" do
  intent = snapshot_intent!([episode_a.id, episode_b.id], snapshot)

  assert {:ok, grab} = Catalog.create_grab_from_intent(intent)
  assert grab.mapping_snapshot == snapshot
  assert grab.mapping_status == :resolved
  assert Enum.sort(episode_ids(grab)) == Enum.sort([episode_a.id, episode_b.id])
  refute Repo.get(Intent, intent.id)
end

test "ownership conflict rolls back the grab and leaves the intent for cleanup" do
  intent = snapshot_intent!([episode_a.id, episode_b.id], snapshot)
  own_episode_with_another_grab!(episode_b)

  assert {:error, :episode_ownership_changed} = Catalog.create_grab_from_intent(intent)
  assert Repo.get!(Intent, intent.id)
  refute Repo.get_by(Grab, download_id: intent.remote_id)
end
```

Also prove standard grabs default to `:resolved` with all four mapping documents nil, a non-nil snapshot cannot be changed after insert, and an unknown `mapping_status` is rejected.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `mix test test/cinder/catalog/grab_mapping_test.exs test/cinder/download/intent_test.exs`

Expected: compilation fails because the fields and `create_grab_from_intent/1` do not exist.

- [ ] **Step 3: Add the five columns and focused changesets**

Use nullable JSON/map columns and a non-null textual enum default:

```elixir
def change do
  alter table(:grabs) do
    add :mapping_snapshot, :map
    add :mapping_status, :string, null: false, default: "resolved"
    add :automatic_mapping_decisions, :map
    add :manual_mapping_overrides, :map
    add :mapping_issue, :map
  end
end
```

Add the schema fields:

```elixir
field :mapping_snapshot, :map
field :mapping_status, Ecto.Enum, values: [:resolved, :needs_mapping], default: :resolved
field :automatic_mapping_decisions, :map
field :manual_mapping_overrides, :map
field :mapping_issue, :map
```

Keep the existing `changeset/2` for operational fields. Add two narrow writers:

```elixir
def reservation_changeset(%__MODULE__{id: nil} = grab, attrs) do
  grab
  |> changeset(attrs)
  |> cast(attrs, [:mapping_snapshot, :mapping_status])
end

def reservation_changeset(%__MODULE__{} = grab, attrs) do
  grab
  |> changeset(attrs)
  |> add_error(:mapping_snapshot, "is immutable")
end

def mapping_changeset(grab, attrs) do
  cast(grab, attrs, [
    :mapping_status,
    :automatic_mapping_decisions,
    :manual_mapping_overrides,
    :mapping_issue
  ])
end
```

- [ ] **Step 4: Transfer snapshot ownership in one database transaction**

Implement `Catalog.create_grab_from_intent/1` as the only snapshot-aware creator:

```elixir
def create_grab_from_intent(%Cinder.Download.Intent{} = intent) do
  result =
    Repo.transaction(fn ->
      fresh = Repo.get(Cinder.Download.Intent, intent.id)
      if is_nil(fresh), do: Repo.rollback(:stale_intent)

      attrs = %{
        download_id: fresh.remote_id,
        download_protocol: fresh.protocol,
        release_title: fresh.release["title"],
        mapping_snapshot: fresh.mapping_snapshot,
        mapping_status: :resolved
      }

      grab =
        %Grab{}
        |> Grab.reservation_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, grab} -> grab
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {linked, _rows} =
        Repo.update_all(
          from(e in Episode,
            where:
              e.id in ^fresh.episode_ids and is_nil(e.grab_id) and
                is_nil(e.file_path) and e.monitored == true
          ),
          set: [grab_id: grab.id, updated_at: now()]
        )

      if linked != length(fresh.episode_ids), do: Repo.rollback(:episode_ownership_changed)
      Repo.delete!(fresh)
      grab
    end)

  with {:ok, grab} <- result do
    broadcast_series(series_id_for_grab(grab.id))
    {:ok, grab}
  end
end
```

The transaction deliberately requires all reserved episodes, not merely one. Keep `create_grab/5` unchanged for standard/manual callers. Change only `Download.reconcile_episodes/1` to select `Catalog.create_grab_from_intent(intent)` when `mapping_snapshot` is non-nil; the existing A2 guard still prevents reaching that branch until Task 6.

- [ ] **Step 5: Verify GREEN, rollback behavior, and standard creation**

Run: `mix format && mix test test/cinder/catalog/grab_mapping_test.exs test/cinder/download/intent_test.exs test/cinder/catalog_test.exs`

Expected: all pass; exact-all linking rolls back conflicts; standard partial-race behavior remains covered by its existing tests.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/cinder/catalog/grab.ex lib/cinder/catalog.ex lib/cinder/download.ex test/cinder/catalog/grab_mapping_test.exs test/cinder/download/intent_test.exs
git commit -m "feat: persist anime grab mappings"
```

### Task 3: Resolve anime files with a pure, exhaustive preflight

**Files:**
- Create: `lib/cinder/library/anime_preflight.ex`
- Create: `test/cinder/library/anime_preflight_test.exs`
- Create: `test/support/fixtures/anime/import-v1.json`

**Interfaces:**
- Consumes: `AnimePreflight.run(snapshot, inventory, overrides, episodes)` where inventory contains relative video paths and identities and episodes contain stable IDs plus canonical season/episode numbers.
- Produces: `{:ok, %{decisions: map(), assignments: [map()]}}` or `{:needs_mapping, %{decisions: map(), issue: map()}}`.
- Reuses: `Cinder.Acquisition.AnimeParser` and `Cinder.Catalog.AnimeResolver`.

- [ ] **Step 1: Add the explicit import corpus**

Create `import-v1.json` with this top-level contract:

```json
{
  "version": 1,
  "cases": [
    {
      "id": "single-standard",
      "snapshot_version": 2,
      "files": ["Frieren - S01E01.mkv"],
      "authoritative_episode_ids": [101],
      "expected": {"status": "resolved", "assignments": {"Frieren - S01E01.mkv": [101]}}
    },
    {
      "id": "cross-season-batch",
      "snapshot_version": 2,
      "files": ["Frieren - 27-29.mkv"],
      "authoritative_episode_ids": [127, 201, 202],
      "expected": {"status": "resolved", "assignments": {"Frieren - 27-29.mkv": [127, 201, 202]}}
    },
    {
      "id": "legacy-snapshot",
      "snapshot_version": 1,
      "files": ["Frieren - 01.mkv"],
      "authoritative_episode_ids": [101],
      "expected": {"status": "needs_mapping", "reason": "legacy_snapshot"}
    }
  ]
}
```

Expand that same array with named cases for: standard multi-episode, absolute single, absolute range, multi-file batch, many-to-many mapping, cross-season output, positive NCOP/NCED/trailer extras, manual ignored extra, ambiguous coordinate, unmatched story file, unknown-role file, missing authoritative episode, outside-authoritative resolution, duplicate episode across files, override success, override conflict, inventory mutation, and version-1 manual-only resolution. Each case carries its complete parser context, snapshot mappings, episode metadata, file identities, overrides, and exact expected decisions; staging cases also carry literal expected destinations or before/after identities. Do not infer expected values in the test from the production resolver.

- [ ] **Step 2: Write a table-driven failing test plus invariant tests**

```elixir
for fixture <- import_cases() do
  test fixture["id"] do
    case unquote(Macro.escape(fixture))["expected"]["status"] do
      "resolved" ->
        assert {:ok, result} = run_fixture(unquote(Macro.escape(fixture)))
        assert assignment_map(result.assignments) == unquote(Macro.escape(fixture))["expected"]["assignments"]

      "needs_mapping" ->
        assert {:needs_mapping, result} = run_fixture(unquote(Macro.escape(fixture)))
        assert result.issue["reason"] == unquote(Macro.escape(fixture))["expected"]["reason"]
    end
  end
end
```

Add direct assertions that resolved output has no absolute path key, decisions contain parser coordinates/role/group plus resolver evidence, and all output maps are Jason-encodable.

- [ ] **Step 3: Run the focused test and verify RED**

Run: `mix test test/cinder/library/anime_preflight_test.exs`

Expected: compilation fails because `Cinder.Library.AnimePreflight` does not exist.

- [ ] **Step 4: Implement one pure pipeline**

Use this public shape:

```elixir
defmodule Cinder.Library.AnimePreflight do
  alias Cinder.Acquisition.AnimeParser
  alias Cinder.Catalog.AnimeResolver

  def run(%{"version" => 1}, inventory, overrides, episodes) do
    authoritative = MapSet.new(Enum.map(episodes, & &1.id))

    inventory
    |> manual_decisions(overrides)
    |> validate(authoritative, fallback_reason: "legacy_snapshot")
    |> result()
  end

  def run(%{"version" => 2} = snapshot, inventory, overrides, episodes) do
    authoritative = MapSet.new(Enum.map(episodes, & &1.id))

    snapshot
    |> parse_inventory(inventory)
    |> apply_overrides(overrides)
    |> resolve_files(snapshot["mappings"])
    |> validate(authoritative)
    |> result()
  end
end
```

For version 1, `manual_decisions/2` accepts the same identity-bound assign/ignore overrides but performs no parsing. If every inventory file has an explicit override and the exact-coverage invariants pass, it returns `{:ok, %{decisions: decisions, assignments: assignments}}`; otherwise the first unassigned file yields `"legacy_snapshot"`. This is the only v1 resume path and never consults live aliases.

Internal data for each file must be a plain map:

```elixir
%{
  relative_path: relative_path,
  identity: identity,
  parsed: %{coordinates: coordinates, role: role, group: group},
  episode_ids: episode_ids,
  source: :automatic | :manual,
  ignored: role == :extra
}
```

Build parser context only from snapshot v2:

```elixir
%{
  kind: :series,
  titles: [context["title"] | context["aliases"]],
  year: context["year"]
}
```

For every non-overridden file, call `AnimeParser.parse(Path.basename(relative_path), context)`. Flatten each parsed `%{scheme: scheme, values: values}` coordinate, select snapshot mappings whose identity has that scheme and a `canonical_value` in `values`, and convert them to the resolver's atom-keyed shape:

```elixir
resolver_mappings =
  Enum.map(matching_snapshot_mappings, fn mapping ->
    %{
      coordinate: atom_identity(mapping["identity"]),
      episode_ids: mapping["episode_ids"],
      precedence: String.to_existing_atom(mapping["precedence"]),
      evidence: mapping["evidence"]
    }
  end)

coordinates = Enum.map(resolver_mappings, & &1.coordinate)

AnimeResolver.resolve(coordinates, resolver_mappings,
  role: parsed.role,
  extra_evidence: parsed.role == :extra and %{parser: "anime_v1"}
)
```

`atom_identity/1` constructs the four known keys (`source`, `scheme`, `namespace`, `canonical_value`) explicitly; it never atomizes arbitrary input. Apply an override only when both `relative_path` and the complete persisted identity equal the current inventory entry. Its action is either `%{"action" => "assign", "episode_ids" => ids}` or `%{"action" => "ignore"}`. A path match with a different identity is `"stale_override"`, never a valid correction. Automatic ignore is valid only when the resolver returns `{:ignore, :extra, evidence}`; a manual ignore is valid for any file and must be marked `source: :manual`.

Validate in this order so one deterministic issue is persisted:

1. reject an override for a path absent from inventory or with a different identity (`"stale_override"`);
2. reject files that remain unmatched or ambiguous after the resolver (`"unresolved_file"`); an `:unknown` parser role is allowed only when its explicit coordinate resolves through a snapshot mapping;
3. reject any resolved ID outside the authoritative set (`"outside_authoritative_set"`);
4. reject an episode ID assigned by two files (`"duplicate_episode_assignment"`);
5. reject any authoritative ID absent from the union (`"missing_episode_assignment"`).

Serialize decisions with string keys and a stable relative-path ordering:

```elixir
%{
  "version" => 1,
  "files" => [
    %{
      "relative_path" => relative_path,
      "size" => identity.size,
      "major_device" => identity.major_device,
      "inode" => identity.inode,
      "mtime" => identity.mtime,
      "parsed" => json_parsed,
      "episode_ids" => episode_ids,
      "source" => "automatic",
      "ignored" => false,
      "evidence" => json_evidence
    }
  ]
}
```

Sort `files` by `relative_path`. A mapping issue is `%{"version" => 1, "reason" => code, "relative_paths" => paths, "candidate_episode_ids" => ids}` so the UI can explain ambiguity without recomputing it. `assignments` is the minimal `%{relative_path: String.t(), episode_ids: [integer()]}` list used by Library; no source path appears in either return value.

- [ ] **Step 5: Verify GREEN and purity**

Run: `mix format && mix test test/cinder/library/anime_preflight_test.exs`

Expected: every import fixture and invariant passes. Confirm the new module has no `Repo`, `File`, `PathPolicy`, HTTP, or web alias with:

```bash
rg -n "Repo|File\.|PathPolicy|Req|CinderWeb" lib/cinder/library/anime_preflight.ex
```

Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/library/anime_preflight.ex test/cinder/library/anime_preflight_test.exs test/support/fixtures/anime/import-v1.json
git commit -m "feat: preflight anime file mappings"
```

### Task 4: Inventory safely and persist mapping evidence before staging

**Files:**
- Modify: `lib/cinder/library.ex:1055-1175`
- Modify: `lib/cinder/catalog.ex:2125-2175`
- Modify: `test/cinder/library_test.exs`
- Modify: `test/cinder/catalog/grab_mapping_test.exs`

**Interfaces:**
- Produces: `Library.preflight_anime_grab/1` and `Library.inventory_anime_videos/1`.
- Produces: `Catalog.record_mapping_result/2` as the only preflight evidence writer.
- Leaves: `TvPoller` routing and ImportStage work for Task 5.

- [ ] **Step 1: Write failing inventory and persistence tests**

Cover a directory and a single-file download. Assert only video extensions are inventoried, paths are relative and sorted, and identity contains all four fields:

```elixir
assert {:ok, %{files: [video], folder?: true}} =
         Library.inventory_anime_videos(download_root)

assert video.relative_path == "Season 1/Frieren - 01.mkv"
refute Map.has_key?(video, :path)
assert %{size: _, major_device: _, inode: _, mtime: _} = video.identity
```

Use the filesystem Mox to prove symlinks/out-of-root paths retain the existing `PathPolicy` rejection. Add Catalog tests:

```elixir
assert {:ok, resolved} =
         Catalog.record_mapping_result(grab, {:ok, %{decisions: decisions}})

assert resolved.mapping_status == :resolved
assert resolved.automatic_mapping_decisions == decisions
assert resolved.mapping_issue == nil

assert {:ok, held} =
         Catalog.record_mapping_result(grab, {:needs_mapping, %{decisions: decisions, issue: issue}})

assert held.mapping_status == :needs_mapping
assert held.automatic_mapping_decisions == decisions
assert held.mapping_issue == issue
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `mix test test/cinder/library_test.exs test/cinder/catalog/grab_mapping_test.exs`

Expected: the new public functions do not exist.

- [ ] **Step 3: Build the bounded inventory through existing path safety**

Reuse `safe_walk/1`, `safe_source_file/1`, and `@video_exts`; do not add a second walker. Normalize both file and directory inputs into `{absolute_path, relative_path, stat}` internally, but return only `%{files: files, folder?: boolean}` where each file is:

```elixir
%{
  relative_path: relative_path,
  identity: %{
    size: stat.size,
    major_device: stat.major_device,
    inode: stat.inode,
    mtime: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
  }
}
```

For a single file, the relative path is `Path.basename(content_path)`. For a directory, use `Path.relative_to(source, content_path)` and reject a result beginning with `../`. Sort by `relative_path` before returning.

Add the adapter:

```elixir
def preflight_anime_grab(%Grab{} = grab) do
  episodes =
    Enum.map(grab.episodes, fn episode ->
      %{
        id: episode.id,
        season_number: episode.season.season_number,
        episode_number: episode.episode_number
      }
    end)

  with {:ok, inventory} <- inventory_anime_videos(grab.content_path) do
    result =
      AnimePreflight.run(
        grab.mapping_snapshot,
        inventory.files,
        get_in(grab.manual_mapping_overrides || %{}, ["files"]) || [],
        episodes
      )

    with {:ok, persisted} <- Catalog.record_mapping_result(grab, result) do
      case result do
        {:ok, preflight} ->
          {:ok, preflight |> Map.put(:grab, persisted) |> Map.put(:folder?, inventory.folder?)}

        {:needs_mapping, preflight} -> {:needs_mapping, Map.put(preflight, :grab, persisted)}
      end
    end
  end
end
```

This is the sole allowed Catalog call from the Library adapter and happens before Task 5 performs staging.

- [ ] **Step 4: Persist evidence with a focused Catalog update**

Implement two clauses using `Grab.mapping_changeset/2`:

```elixir
def record_mapping_result(%Grab{} = grab, {:ok, %{decisions: decisions}}) do
  grab
  |> Grab.mapping_changeset(%{
    mapping_status: :resolved,
    automatic_mapping_decisions: decisions,
    mapping_issue: nil
  })
  |> Repo.update()
end

def record_mapping_result(
      %Grab{} = grab,
      {:needs_mapping, %{decisions: decisions, issue: issue}}
    ) do
  grab
  |> Grab.mapping_changeset(%{
    mapping_status: :needs_mapping,
    automatic_mapping_decisions: decisions,
    mapping_issue: issue
  })
  |> Repo.update()
end
```

Wrap each `Repo.update/1` result so a successful mapping-state change broadcasts `{:series_updated, series_id}` exactly once after the write. The broadcast is best-effort post-write and does not turn a persisted hold into an import retry.

Do not change counters, delete the grab, blocklist the release, or touch episode links in either clause.

- [ ] **Step 5: Verify GREEN and no path leakage**

Run: `mix format && mix test test/cinder/library_test.exs test/cinder/catalog/grab_mapping_test.exs`

Expected: focused tests pass. Add `Jason.encode!` assertions for both persisted documents and refute the configured download root string is present in the JSON.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/library.ex lib/cinder/catalog.ex test/cinder/library_test.exs test/cinder/catalog/grab_mapping_test.exs
git commit -m "feat: persist anime import preflight"
```

### Task 5: Stage anime assignments atomically across season destinations

**Files:**
- Modify: `lib/cinder/library.ex:1055-1395`
- Modify: `lib/cinder/catalog.ex:2152-2162`
- Modify: `lib/cinder/download/tv_poller.ex:104-178`
- Modify: `test/support/fixtures/anime/import-v1.json`
- Modify: `test/cinder/library_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`

**Interfaces:**
- Produces: `Library.stage_anime_episodes/2` accepting a grab and persisted preflight result.
- Routes: snapshot grabs through preflight and explicit assignments; nil-snapshot grabs remain on `stage_episodes/2`.
- Holds: `:needs_mapping` grabs outside the import sweep until recovery sets them back to `:resolved`.

- [ ] **Step 1: Write failing staging, mutation, and poller tests**

Add Library tests proving:

1. one source assigned to two episodes in the same season yields one destination and one stage;
2. one source assigned across two seasons yields one canonical destination per season and two stages;
3. a failure staging the second season rolls back the first season's stage;
4. changing size, inode/device, or mtime after preflight requests a complete fresh preflight before a stage is created;
5. destination names use the existing tmdb-tagged series directory and `SxxEyy` naming.

Drive the cross-season and inventory-race tests from the fixture's explicit `expected.destinations`, `before_inventory`, and `after_inventory` values so the same corpus covers pure decisions and filesystem staging without deriving expectations from production helpers.

The cross-season assertion is explicit:

```elixir
assert {:ok, staged} = Library.stage_anime_episodes(grab, preflight)

assert staged
       |> Enum.map(fn {episode_id, stage} -> {episode_id, Path.dirname(stage.dest)} end)
       |> Map.new() == %{
         season_one_episode.id => Path.join(series_root, "Season 01"),
         season_two_episode.id => Path.join(series_root, "Season 02")
       }
```

Add TvPoller tests proving a standard grab still calls the existing path, a resolved snapshot grab persists decisions before the first hardlink/copy, an ambiguous grab becomes `:needs_mapping` without attempt increments or client removal, and a held grab is not processed again on the next tick.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `mix test test/cinder/library_test.exs test/cinder/download/tv_poller_test.exs`

Expected: `stage_anime_episodes/2` is missing and TvPoller still routes every downloaded grab through the standard parser.

- [ ] **Step 3: Revalidate persisted inventory and build explicit episode/source pairs**

Use this public contract:

```elixir
def stage_anime_episodes(%Grab{} = grab, preflight) do
  with {:ok, current} <- inventory_anime_videos(grab.content_path),
       :ok <- same_inventory(current.files, preflight.decisions),
       :ok <- same_container_kind(current.folder?, preflight.folder?),
       {:ok, root} <- root(:tv),
       {:ok, to_import} <- anime_import_pairs(grab, preflight.assignments) do
    stage_anime_all(to_import, root, episode_target(grab.episodes), current.folder?)
  else
    {:error, :inventory_changed} ->
      {:restart_preflight, :inventory_changed}

    {:error, _reason} = error ->
      error
  end
end
```

`same_container_kind/2` returns `:ok` only for equal booleans and `{:error, :inventory_changed}` otherwise. `same_inventory/2` compares the sorted `%{relative_path, identity}` values against the exact flat `relative_path`, `size`, `major_device`, `inode`, and `mtime` values persisted in `decisions["files"]`. `anime_import_pairs/2` must:

- index `grab.episodes` by stable ID;
- reject any assignment ID absent from that authoritative index;
- reconstruct each source with `Path.join(grab.content_path, relative_path)` for a directory, or use `grab.content_path` only when the relative path equals its basename;
- pass every reconstructed source through `safe_source_file/1`;
- return `{episode, absolute_source}` pairs without reparsing a filename.

- [ ] **Step 4: Add a season-aware staging reducer without changing the standard reducer**

Do not modify `stage_all/4`. Add a sibling that groups by source and season:

```elixir
defp stage_anime_all(to_import, root, target, folder?) do
  to_import
  |> Enum.group_by(
    fn {episode, source} -> {source, episode.season.season_number} end,
    fn {episode, _source} -> episode end
  )
  |> Enum.sort_by(fn {{source, season}, _episodes} -> {source, season} end)
  |> Enum.reduce_while({:ok, []}, fn {{source, _season}, episodes}, {:ok, acc} ->
    episodes = Enum.sort_by(episodes, & &1.episode_number)

    case stage_episode_file(episodes, source, root, target, folder?) do
      {:ok, stage} ->
        rows = Enum.map(episodes, &{&1.id, stage})
        {:cont, {:ok, Enum.reverse(rows, acc)}}

      {:error, _reason} = error ->
        acc
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq_by(& &1.dest)
        |> Enum.each(&rollback_stage/1)

        {:halt, error}
    end
  end)
end
```

This intentionally creates one hardlink/copy per season when a single source spans a season boundary, so canonical directory and episode-code rules remain valid. It continues through the existing `stage_episode_file/5`, so MediaInfo capture may populate current quality fields; A3 adds no new audio, subtitle, or group rejection.

- [ ] **Step 5: Route snapshot grabs through the safe branch**

Exclude held grabs from the Catalog import query while retaining standard default-resolved rows:

```elixir
from g in Grab,
  where: not is_nil(g.content_path) and g.mapping_status == :resolved,
  preload: [episodes: [season: :series]]
```

Split `TvPoller.import_grab/1` only at the top:

```elixir
defp import_grab(%Grab{mapping_snapshot: nil} = grab), do: import_standard_grab(grab)

defp import_grab(%Grab{} = grab) do
  case Library.preflight_anime_grab(grab) do
    {:ok, preflight} ->
      case Library.stage_anime_episodes(preflight.grab, preflight) do
        {:ok, staged} -> finalize_staged_grab(preflight.grab, staged)
        {:restart_preflight, :inventory_changed} -> :ok
        {:error, reason} -> retry_or_park(preflight.grab, reason)
      end

    {:needs_mapping, _result} ->
      :ok

    {:error, :library_not_configured} ->
      hold_for_configuration(grab, :tv_library_path)

    {:error, :download_roots_not_configured} ->
      hold_for_configuration(grab, :download_import_roots)

    {:error, reason} ->
      retry_or_park(grab, reason)
  end
end
```

Extract the current standard body to `import_standard_grab/1`, and extract its existing `finish_grab`/commit/remove block to `finalize_staged_grab/2`. The helper must preserve current stale-grab rollback, bounded finalize retry, unique-stage commit, and downloader removal behavior. Configuration holds log only; they do not change mapping status or counters.

- [ ] **Step 6: Verify GREEN and standard regression coverage**

Run: `mix format && mix test test/cinder/library_test.exs test/cinder/download/tv_poller_test.exs test/cinder/catalog/grab_mapping_test.exs`

Expected: all pass; the standard parser/import assertions remain unchanged; an anime preflight hold creates no ImportStage row; an inventory race leaves the grab resolved so the next poll performs a complete fresh inventory and preflight without a counter bump.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/library.ex lib/cinder/catalog.ex lib/cinder/download/tv_poller.ex test/support/fixtures/anime/import-v1.json test/cinder/library_test.exs test/cinder/download/tv_poller_test.exs
git commit -m "feat: stage anime imports safely"
```

### Task 6: Activate stable-ID anime polling only after safe import exists

**Files:**
- Modify: `lib/cinder/download/tv_poller.ex:197-265`
- Modify: `lib/cinder/download.ex:105-255,600-625`
- Modify: `test/cinder/download/tv_poller_test.exs`
- Modify: `test/cinder/download/intent_test.exs`

**Interfaces:**
- Routes: effective standard series to existing season-number search; effective anime series to `Acquisition.best_anime_releases/3` grouped by series stable IDs.
- Activates: snapshot-bearing `Download.grab_episodes/2`, intent submission, reconciliation, and restart recovery.
- Keeps: bounded A2 query planning and preferred-group options only; A3 adds no setting or UI.

- [ ] **Step 1: Replace the A2 hold assertions with failing end-to-end intent tests**

Add tests for:

```elixir
test "anime poll groups wanted episodes across seasons by series and reserves marked assignments" do
  # two wanted episodes in different seasons of an explicit anime series
  # one A2 selection covers both stable IDs
  poll()

  assert %Intent{mapping_snapshot: %{"version" => 2}} = intent_for([episode_a.id, episode_b.id])
  assert_called_indexer_queries_are_bounded()
end

test "restart reconciliation creates one snapshot grab with every reserved episode" do
  intent = submitted_snapshot_intent!([episode_a.id, episode_b.id])

  restart_tv_poller()
  poll()

  assert %Grab{mapping_snapshot: snapshot} = grab_for_remote(intent.remote_id)
  assert Enum.sort(grab_episode_ids(intent.remote_id)) == Enum.sort(intent.episode_ids)
  refute Repo.get(Intent, intent.id)
end
```

Retain a standard-series assertion that `search_tv/3` receives the same season number and episode numbers as before. Add a conflict test proving the remote download is fenced for cleanup when exact episode ownership fails. Add a restart test that changes the series' live provider aliases after reservation and proves the downloaded filename is still interpreted with `snapshot["parser_context"]`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `mix test test/cinder/download/tv_poller_test.exs test/cinder/download/intent_test.exs`

Expected: A2 returns `:anime_import_not_ready`, pending reconciliation excludes snapshots, and TvPoller calls only `best_releases/4`.

- [ ] **Step 3: Split wanted search by effective media profile**

After pending/backoff filtering, group first by series ID. For each series:

```elixir
defp search_series(episodes) do
  series = hd(episodes).season.series

  case Catalog.media_profile_summary(series).effective do
    :anime -> search_anime_series(series, episodes)
    :standard ->
      episodes
      |> Enum.group_by(& &1.season.season_number)
      |> Enum.each(fn {_season_number, group} -> search_standard_group(group) end)
  end
end
```

Keep the current standard body in `search_standard_group/1`. The anime branch passes stable IDs and the Catalog-owned identity context:

```elixir
defp search_anime_series(series, episodes) do
  wanted_ids = Enum.map(episodes, & &1.id)
  context = Catalog.anime_series_acquisition_context(series)

  opts =
    [
      protocols: Download.available_protocols(),
      preferred_language: series.preferred_language,
      original_language: series.original_language,
      release_blocklist: Catalog.blocked_release_titles_for_series(series.id)
    ] ++ Acquisition.band_opts(:tv)

  case Acquisition.best_anime_releases(context, wanted_ids, opts) do
    {:ok, %{assignments: assignments, waiting: waiting}} ->
      grabbed = Enum.flat_map(assignments, &grab_anime_assignment/1)
      held = if waiting, do: waiting.episode_ids, else: []
      bump_not_grabbed(episodes, grabbed ++ held)

    {:waiting_for_preferred_group, waiting} ->
      bump_not_grabbed(episodes, waiting.episode_ids)

    :no_match ->
      bump_not_grabbed(episodes, [])

    {:error, reason} ->
      log_search_failure(series, reason)
      bump_not_grabbed(episodes, [])
  end
end

defp grab_anime_assignment(%{release: release, episode_ids: episode_ids}) do
  case Download.grab_episodes(release, episode_ids) do
    {:ok, _grab} -> episode_ids
    _failure -> []
  end
end
```

No search fanout is added here; A2's planner remains the only anime query source.

- [ ] **Step 4: Remove all three A2 side-effect guards together**

Delete the snapshot clauses returning `:anime_import_not_ready` from `grab_episodes/2`, `do_submit_intent/1`, and `do_reconcile_intent/1`. Include `mapping_snapshot` when reserving:

```elixir
reserve_intent(%{
  kind: kind,
  target_id: hd(episode_ids),
  episode_ids: episode_ids,
  protocol: release.protocol,
  release: release,
  mapping_snapshot: release.mapping_snapshot
})
```

Change pending reconciliation to include every requested kind, not only nil-snapshot intents:

```elixir
where: i.kind in ^kinds,
order_by: [asc: i.id]
```

In `reconcile_episodes/1`, route snapshot intents to `Catalog.create_grab_from_intent/1`; keep the current `Catalog.create_grab/5` standard branch. On either creation error, retain the existing `cleanup_failed_ownership/2` fence so a remote download never survives without a local owner.

- [ ] **Step 5: Verify GREEN, crash recovery, and no standard drift**

Run: `mix format && mix test test/cinder/download/tv_poller_test.exs test/cinder/download/intent_test.exs test/cinder/acquisition_test.exs`

Expected: anime intents survive restart and become exact-all grabs; standard TV tests still use the original season grouping and result shape.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/download/tv_poller.ex lib/cinder/download.ex test/cinder/download/tv_poller_test.exs test/cinder/download/intent_test.exs
git commit -m "feat: activate anime episode acquisition"
```

### Task 7: Add transactional mapping recovery and optional identity promotion

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Modify: `test/cinder/catalog/grab_mapping_test.exs`

**Interfaces:**
- Produces: `Catalog.get_mapping_grab/1`, `Catalog.list_mapping_grabs_for_series/1`, `Catalog.resume_grab_mapping/2`, and `Catalog.promote_grab_mapping/2`.
- Reuses: `Catalog.cancel_grab/1` unchanged for cancellation.
- Reuses: `Catalog.put_episode_coordinate/3` for explicit promotion; no direct identity-table write.

- [ ] **Step 1: Write failing transaction and promotion tests**

Cover all recovery invariants:

```elixir
test "resume atomically replaces current targets and stores explanatory overrides" do
  assert {:ok, resumed} =
           Catalog.resume_grab_mapping(grab, %{
             "files" => [
               %{
                 "relative_path" => "Frieren - 28.mkv",
                 "action" => "assign",
                 "episode_ids" => [episode_b.id]
               }
             ],
             "target_episode_ids" => [episode_b.id],
             "monitor_episode_ids" => []
           })

  assert resumed.mapping_status == :resolved
  assert resumed.mapping_issue == nil
  assert resumed.manual_mapping_overrides["original_episode_ids"] == [episode_a.id]
  assert resumed.manual_mapping_overrides["target_episode_ids"] == [episode_b.id]
  assert Repo.get!(Episode, episode_a.id).grab_id == nil
  assert Repo.get!(Episode, episode_a.id).search_attempts == 0
  assert Repo.get!(Episode, episode_b.id).grab_id == grab.id
end
```

Add independent rollback tests for a target in another series, an already available target, a target owned by another grab, a target reserved by an active intent, an unmonitored target without opt-in, duplicate IDs, empty target set, stale/deleted grab, and a grab no longer in `:needs_mapping`. Assert the original links and mapping document remain unchanged after every failure.

Promotion tests must prove `Catalog.promote_grab_mapping/2` accepts only `%{"relative_path" => path, "scheme" => scheme, "value" => value, "episode_ids" => ids}` whose coordinate is already present in a persisted decision, creates a manual coordinate with the explicitly selected same-series episode order, rejects a non-reusable/unknown decision or foreign/duplicate episode ID, and changes neither `mapping_snapshot` nor `manual_mapping_overrides`.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/catalog/grab_mapping_test.exs`

Expected: the four recovery functions do not exist.

- [ ] **Step 3: Add recovery reads with correct preloads**

Implement:

```elixir
def get_mapping_grab(id) do
  Repo.one(
    from g in Grab,
      where: g.id == ^id and not is_nil(g.mapping_snapshot),
      preload: [episodes: [season: :series]]
  )
end

def list_mapping_grabs_for_series(series_id) do
  Repo.all(
    from g in Grab,
      join: episode in assoc(g, :episodes),
      join: season in assoc(episode, :season),
      where: season.series_id == ^series_id and g.mapping_status == :needs_mapping,
      distinct: true,
      order_by: [asc: g.id],
      preload: [episodes: [season: :series]]
  )
end
```

- [ ] **Step 4: Replace target ownership and persist overrides in one transaction**

`resume_grab_mapping/2` must re-read the grab inside the transaction, normalize unique positive integer target and monitor IDs, and reject stale state. Query target episodes joined through seasons and IntentEpisode reservations. Validate same-series ownership using the series of the current grab. Only IDs listed in `monitor_episode_ids` may change from `monitored: false` to true.

Store this canonical document:

```elixir
override_document = %{
  "version" => 1,
  "files" => identity_bound_overrides(fresh.automatic_mapping_decisions, attrs["files"]),
  "original_episode_ids" => fresh.mapping_snapshot["reserved_episode_ids"],
  "target_episode_ids" => target_ids,
  "monitor_episode_ids" => monitor_ids
}
```

`attrs["files"]` contains only relative paths and actions from the browser. `identity_bound_overrides/2` must find each path in the persisted automatic decision list and return sorted entries containing `relative_path`, the decision's exact flat `size`, `major_device`, `inode`, and `mtime` values, `action`, and `episode_ids`. Omit `episode_ids` only for `"ignore"`. Reject an unknown path, duplicate path, malformed action, empty assignment, or assignment outside `target_ids`; never accept identity or evidence fields supplied by the client.

Then perform exactly these writes in one `Repo.transaction/1`:

```elixir
Repo.update_all(
  from(e in Episode, where: e.grab_id == ^fresh.id and e.id not in ^target_ids),
  set: [grab_id: nil, updated_at: now()]
)

Repo.update_all(
  from(e in Episode, where: e.id in ^monitor_ids),
  set: [monitored: true, updated_at: now()]
)

{linked, _rows} =
  Repo.update_all(
    from(e in Episode,
      where:
        e.id in ^target_ids and is_nil(e.file_path) and
          (is_nil(e.grab_id) or e.grab_id == ^fresh.id) and e.monitored == true
    ),
    set: [grab_id: fresh.id, updated_at: now()]
  )

if linked != length(target_ids), do: Repo.rollback(:episode_ownership_changed)

fresh
|> Grab.mapping_changeset(%{
  mapping_status: :resolved,
  manual_mapping_overrides: override_document,
  mapping_issue: nil
})
|> Repo.update()
|> case do
  {:ok, updated} -> updated
  {:error, changeset} -> Repo.rollback(changeset)
end
```

The exact count is safe because all target IDs were deduplicated and all existing links are included by the predicate. Removed episodes keep their current `search_attempts`; do not bump or reset them. Broadcast once after commit.

- [ ] **Step 5: Promote only explicit reusable coordinates through Identity**

`promote_grab_mapping(grab, %{"relative_path" => path, "scheme" => scheme, "value" => value, "episode_ids" => episode_ids})` re-reads the grab and requires it is still `:needs_mapping`, reads the persisted decision for that path, verifies the exact scheme/value is present in its parsed coordinates, requires a non-empty ordered episode list, validates every ID belongs to the current series, reloads the series, and calls:

```elixir
Catalog.put_episode_coordinate(
  series,
  %{
    source: "manual",
    scheme: scheme,
    namespace: "mapping-recovery",
    canonical_value: value,
    precedence: :manual
  },
  episode_ids
)
```

If the parser emitted a range or multiple coordinate values, the UI promotes one decision value at a time. Never derive identity from a free-form browser field.

- [ ] **Step 6: Verify GREEN and cancellation compatibility**

Run: `mix format && mix test test/cinder/catalog/grab_mapping_test.exs test/cinder/catalog/anime_identity_test.exs test/cinder/download/tv_poller_test.exs`

Expected: recovery invariants pass, promotion uses existing precedence rules, and `Catalog.cancel_grab/1` still fences/removes a held download.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog/grab_mapping_test.exs
git commit -m "feat: recover held anime mappings"
```

### Task 8: Expose one shared admin mapping-recovery page

**Files:**
- Create: `lib/cinder_web/live/grab_mapping_live.ex`
- Create: `test/cinder_web/live/grab_mapping_live_test.exs`
- Modify: `lib/cinder_web/router.ex:68-86`
- Modify: `lib/cinder_web/live/activity_live.ex`
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Modify: `lib/cinder_web/components/core_components.ex:637-760`
- Modify: `test/cinder_web/live/activity_live_test.exs`
- Modify: `test/cinder_web/live/series_detail_live_test.exs`

**Interfaces:**
- Adds: admin-only `GET /activity/grabs/:id/mapping` served by `CinderWeb.GrabMappingLive`.
- Links: the same page from Activity and Series Detail.
- Actions: save-and-retry, promote one verified coordinate, and cancel via `Catalog.cancel_grab/1`.

- [ ] **Step 1: Write failing route, rendering, and action tests**

Use `live/2` and stable DOM IDs to prove:

- unauthenticated and non-admin scopes cannot open the route;
- a missing, standard, or non-held grab redirects to Activity with an error;
- `#mapping-release`, `#mapping-original-targets`, `#mapping-current-targets`, and one `#mapping-file-<index>` row render;
- no absolute download root is present in `render(view)`;
- assignments and ignores submit exact integer IDs to Catalog and redirect back to Activity;
- stale save stays on the page with an error;
- promotion is available only for a persisted reusable coordinate;
- cancel uses the existing remote cleanup fence;
- Activity and Series Detail both link to the identical route.

- [ ] **Step 2: Run the web tests and verify RED**

Run: `mix test test/cinder_web/live/grab_mapping_live_test.exs test/cinder_web/live/activity_live_test.exs test/cinder_web/live/series_detail_live_test.exs`

Expected: route/helper/module and `:needs_mapping` badge are missing.

- [ ] **Step 3: Add the route and strict mount gate**

Inside the existing `live_session :admin` block:

```elixir
live "/activity/grabs/:id/mapping", GrabMappingLive
```

Mount only a held snapshot grab:

```elixir
def mount(%{"id" => id}, _session, socket) do
  with {id, ""} <- Integer.parse(id),
       %Grab{mapping_status: :needs_mapping} = grab <- Catalog.get_mapping_grab(id) do
    if connected?(socket), do: Catalog.subscribe_series()

    {:ok,
     assign(socket,
       grab: grab,
       series: hd(grab.episodes).season.series,
       form: mapping_form(grab),
       promoting: nil,
       confirming_cancel?: false
     )}
  else
    _ ->
      {:ok,
       socket
       |> put_flash(:error, gettext("That mapping no longer needs attention."))
       |> push_navigate(to: ~p"/activity")}
  end
end
```

`mapping_form/1` is built only from relative-path decisions and missing episodes from `Catalog.get_series_with_tree(series.id)`. Its submitted shape is the exact Task 7 document:

```elixir
%{
  "files" => [
    %{
      "relative_path" => relative_path,
      "action" => "assign",
      "episode_ids" => ["123", "124"]
    }
  ],
  "target_episode_ids" => ["123", "124"],
  "monitor_episode_ids" => ["124"]
}
```

Normalize integer strings server-side before calling Catalog; ignore unknown keys and reject malformed IDs with a visible form error. The client never supplies file identity or resolver evidence; Catalog binds actions to the current persisted decision identities inside the guarded transaction.

- [ ] **Step 4: Implement the three events with stale re-reads**

```elixir
def handle_event("save_and_retry", %{"mapping" => attrs}, socket) do
  with %Grab{mapping_status: :needs_mapping} = grab <- Catalog.get_mapping_grab(socket.assigns.grab.id),
       {:ok, normalized} <- normalize_mapping(attrs),
       {:ok, _grab} <- Catalog.resume_grab_mapping(grab, normalized) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Mapping saved. Import will retry shortly."))
     |> push_navigate(to: ~p"/activity")}
  else
    _failure -> {:noreply, put_flash(socket, :error, gettext("The mapping could not be saved."))}
  end
end

def handle_event("promote", params, socket) do
  with %Grab{mapping_status: :needs_mapping} = grab <-
         Catalog.get_mapping_grab(socket.assigns.grab.id),
       {:ok, _coordinate} <- Catalog.promote_grab_mapping(grab, promotion(params)) do
    {:noreply, put_flash(socket, :info, gettext("Coordinate saved for future releases."))}
  else
    _failure -> {:noreply, put_flash(socket, :error, gettext("That coordinate cannot be promoted."))}
  end
end

def handle_event("confirm_cancel", _params, socket) do
  with %Grab{mapping_status: :needs_mapping} = grab <-
         Catalog.get_mapping_grab(socket.assigns.grab.id),
       {:ok, _deleted} <- Catalog.cancel_grab(grab) do
    {:noreply, push_navigate(socket, to: ~p"/activity")}
  else
    _failure -> {:noreply, put_flash(socket, :error, gettext("The download could not be cancelled."))}
  end
end
```

`promotion(params)` takes the selected assignment IDs from the same file row and normalizes them as ordered positive integers; Catalog still revalidates same-series ownership. The poller performs filesystem work after Save; the LiveView never calls Library.

- [ ] **Step 5: Render evidence, target delta, and explicit controls**

Render:

- release title and original snapshot coordinates under `#mapping-release`;
- original snapshot reserved IDs under `#mapping-original-targets`;
- current linked episode codes under `#mapping-current-targets`;
- each relative file name, identity, parsed role/group/coordinates, resolver candidates/evidence, assignment checkboxes, and Ignore choice in `#mapping-file-<index>`;
- additions/removals and monitor opt-ins in `#mapping-target-delta`;
- Save and retry, Promote, and Cancel buttons with confirmation for Cancel.

Use existing `.header`, `.button`, `.input`, `.confirm_action`, and status components. Do not add a new component layer for this one page. File identities render as size plus inode/device/mtime, never a source root.

Add the explicit badge:

```elixir
defp badge_spec(:grab, :needs_mapping),
  do: {gettext("Needs mapping"), "badge-warning", "hero-exclamation-triangle"}
```

Return `:needs_mapping` before content-path inference in Activity:

```elixir
defp grab_state(%{mapping_status: :needs_mapping}), do: :needs_mapping
defp grab_state(%{content_path: nil}), do: :downloading
defp grab_state(_grab), do: :downloaded
```

Render a `Review mapping` link for held grabs. In Series Detail, assign `mapping_grabs: Catalog.list_mapping_grabs_for_series(series.id)` on mount/reload and render the same route for each row.

- [ ] **Step 6: Verify GREEN, accessibility, and path privacy**

Run: `mix format && mix test test/cinder_web/live/grab_mapping_live_test.exs test/cinder_web/live/activity_live_test.exs test/cinder_web/live/series_detail_live_test.exs`

Expected: all pass; labels are associated with inputs; keyboard-submitted forms work; no absolute content path appears in HTML or flash messages.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/live/grab_mapping_live.ex lib/cinder_web/router.ex lib/cinder_web/live/activity_live.ex lib/cinder_web/live/series_detail_live.ex lib/cinder_web/components/core_components.ex test/cinder_web/live/grab_mapping_live_test.exs test/cinder_web/live/activity_live_test.exs test/cinder_web/live/series_detail_live_test.exs
git commit -m "feat: add anime mapping recovery UI"
```

### Task 9: Close A3 with the full fixture, graph, and roadmap gate

**Files:**
- Modify: `ROADMAP.md`
- Update generated graph: `graphify-out/`

**Interfaces:**
- Verifies: every A3 Done-when invariant through the repository quality alias.
- Records: A3 complete in the authoritative roadmap only after every check passes.

- [ ] **Step 1: Audit fixture coverage by stable case ID**

Run:

```bash
jq -r '.cases[].id' test/support/fixtures/anime/import-v1.json | sort
```

Confirm the output contains explicit cases for all of these categories: standard single/multi, absolute single/range, multi-file batch, many-to-many, cross-season, positive extra, manual extra, ambiguous, unmatched, unknown, missing, outside-authoritative, duplicate, inventory mutation, and legacy v1 snapshot. If any category is absent, return to Task 3 or Task 5 and complete that task before continuing this phase gate.

- [ ] **Step 2: Run the complete anime and web regression slice**

Run:

```bash
mix test \
  test/cinder/acquisition/anime_parser_test.exs \
  test/cinder/acquisition/anime_search_test.exs \
  test/cinder/acquisition/anime_selection_test.exs \
  test/cinder/catalog/anime_resolver_test.exs \
  test/cinder/download/intent_test.exs \
  test/cinder/catalog/grab_mapping_test.exs \
  test/cinder/library/anime_preflight_test.exs \
  test/cinder/library_test.exs \
  test/cinder/download/tv_poller_test.exs \
  test/cinder_web/live/grab_mapping_live_test.exs \
  test/cinder_web/live/activity_live_test.exs \
  test/cinder_web/live/series_detail_live_test.exs
```

Expected: zero failures and no network access.

- [ ] **Step 3: Run the repository source-of-truth gate**

Run: `mix test`

Expected: compile with warnings-as-errors, format check, strict Credo, and the entire ExUnit suite all pass.

- [ ] **Step 4: Refresh and inspect the code graph**

Run:

```bash
graphify update .
graphify query "How do snapshot anime grabs move from download intent through preflight, recovery, and import?"
git status --short
```

Expected: the graph includes `AnimePreflight`, grab mapping state, `TvPoller`, and `GrabMappingLive`; only intentional source, test, roadmap, and generated graph changes remain.

- [ ] **Step 5: Mark only A3 complete in ROADMAP.md**

Change the A3 heading/status and Done-when checklist to completed form. Preserve A4 and every later phase unchanged. The completion note must name the durable hold/resume behavior and the import fixture; it must not claim A4 preference enforcement.

- [ ] **Step 6: Re-run formatting and the full gate after roadmap/graph changes**

Run: `mix format && mix test`

Expected: all checks pass.

- [ ] **Step 7: Commit the phase boundary**

```bash
git add ROADMAP.md graphify-out
git commit -m "docs: complete A3 anime import recovery"
```

Do not start A4 in this branch or session.
