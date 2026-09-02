defmodule Cinder.Library.MigrationAdoption.Readarr do
  @moduledoc """
  Bounded, cached, **preview-only** candidate classification for adopting Bookshelf's existing
  e-book library — `docs/plans/2026-09-01-books-b6-migration-and-cutover.md` §B6b.

  A sibling extraction from `Cinder.Library.MigrationAdoption`, the same "carved out as plain
  code motion" pattern `Cinder.Settings.Registry`/`Crypto` already established, not a new
  top-level namespace. `MigrationAdoption.plan/4`'s `:readarr` clause delegates straight to
  `plan/1` below.

  ## Two passes, cheap-local-filter first

  Movies/TV batch their identity lookups up front through `MigrationReconciler` — a pure
  function with no I/O of its own, fed by one bulk TMDB call per unique external id. Books have
  no such batchable primitive: `Cinder.Books.Identity.resolve/1` is a real network call issued
  one candidate at a time (its free-text path alone walks every configured metadata provider,
  up to three sequential HTTP requests per work — `identity.ex:128-146`). Shoehorning that
  through `MigrationReconciler`'s "resolve everything up front" architecture would be exactly the
  uncapped loop the roadmap warns about, so `migration_reconciler.ex` is untouched and books get
  their own bounded loop here, mirroring `Cinder.Books.preview_author_policy/2`'s own two-pass
  doc almost verbatim:

  1. **Cheap, local, no network.** Every file-bearing work is checked against
     `book_identifiers{provider: "readarr", kind: "work", foreign_id: work.foreign_id}` — one
     bulk indexed read, no HTTP. A hit resolves the work locally and proceeds straight to file
     classification.
  2. **Network-bound, capped.** Every miss is a candidate for `Identity.resolve/1`, called with a
     free-text query built from the work's author name plus its title — but at most
     `Cinder.Books.max_bibliography_candidates/0` per `plan/1` call. Beyond the cap, a work is
     simply not yet a candidate; its count surfaces through `summary/1`'s `:remaining`, exactly
     the field `preview_author_policy/2` already returns for the same reason.

  A work step 2 actually attempts — resolved or not — becomes a visible, explained candidate:
  `:blocked, {:unresolved_identity, reason}` on failure, classified by file below on success.
  This is what distinguishes `:blocked` from `:remaining` — `remaining` counts works the cap
  never reached this call, `:blocked` counts works the cap *did* reach where identity could not
  resolve one.

  ## Write boundary

  `plan/1` and `summary/1` perform **zero** database writes. `Identity.resolve/1` is already
  read-only (`get_work/1`, never `Cinder.Books.import_resolution/1`), and every other read here
  (`book_identifiers`, `book_targets`, `book_files`, `book_editions`) is a plain `Repo.all`/`Ecto`
  query, never an insert/update/delete. This is what makes "a dry run changes nothing" true by
  construction, not by a separate check. B6c owns the write path.
  """

  import Ecto.Query

  alias Cinder.Acquisition.BookScorer
  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookTarget, Edition, Identifier}
  alias Cinder.Books.Identity
  alias Cinder.Library.MigrationSource
  alias Cinder.Repo
  alias Cinder.Settings

  # The parity contract's e-book profile, most preferred first — reusing `BookScorer`'s own list
  # rather than a second one, so the release scorer and the migration classifier can never drift
  # on what "accepted" means.
  @accepted_formats Enum.map(BookScorer.accepted_formats(), &to_string/1)

  @doc """
  Classifies every file-bearing work in `snapshot` into one `:readarr` candidate, mirroring
  `MigrationAdoption`'s `movie_candidate/4` cond-chain style. See the module doc and the B6b plan
  §3 for the classification rules.

  A monitored work with no file never reaches this function at all — see `summary/1`'s
  `:deferred_bibliography_count`.
  """
  @spec plan(MigrationSource.snapshot()) :: [map()]
  def plan(snapshot) do
    files_by_work = files_by_work(snapshot)
    file_bearing = file_bearing_works(snapshot, files_by_work)

    identifiers = local_identifier_index(file_bearing)
    {cached, uncached} = Enum.split_with(file_bearing, &Map.has_key?(identifiers, &1.foreign_id))
    {to_resolve, _remaining} = Enum.split(uncached, Books.max_bibliography_candidates())

    authors_by_id = Map.new(Map.get(snapshot, :authors, []), &{&1.provider_id, &1})
    resolutions = Map.new(to_resolve, &{&1.provider_id, resolve(&1, authors_by_id)})
    editions_by_work = Enum.group_by(Map.get(snapshot, :editions, []), & &1.work_id)

    cached_identity =
      Map.new(cached, &{&1.provider_id, {:cached, Map.fetch!(identifiers, &1.foreign_id)}})

    identity_by_provider_id = Map.merge(cached_identity, resolved_identity_map(resolutions))
    catalog = catalog_state(identity_by_provider_id, files_by_work)

    (cached ++ to_resolve)
    |> Enum.map(fn work ->
      candidate(
        work,
        Map.fetch!(identity_by_provider_id, work.provider_id),
        Map.get(files_by_work, work.provider_id, []),
        Map.get(editions_by_work, work.provider_id, []),
        catalog
      )
    end)
  end

  @doc """
  Preview summary fields no other migration source needs.

  `remaining` is how many not-yet-attempted works `plan/1`'s cap left this call — the identical
  field name and meaning `Books.preview_author_policy/2` already returns. `deferred_bibliography_count`
  is the count of monitored, fileless works (661 of the eBook instance's 842, in the real
  deployment) that never became candidates at all: importing every monitored source row as an
  active acquisition request would be the "back-catalogue flood" the parity contract's own
  cutover-hazard section warns against, so this is pure snapshot arithmetic, never a candidate.

  Both fields are cheap, local-DB-only reads — nothing here issues a metadata-provider HTTP
  request. This redoes `plan/1`'s local identifier-cache lookup once more (one extra indexed
  `book_identifiers` read per `MigrationAdoption.preview/1` call) rather than threading a second
  return value through `plan/4`'s list-returning contract every other migration source relies on
  unchanged — see `MigrationAdoption.extra_fields/2`.
  """
  @spec summary(MigrationSource.snapshot()) :: %{
          remaining: non_neg_integer(),
          deferred_bibliography_count: non_neg_integer()
        }
  def summary(snapshot) do
    files_by_work = files_by_work(snapshot)
    file_bearing = file_bearing_works(snapshot, files_by_work)
    file_bearing_ids = MapSet.new(files_by_work, fn {work_id, _files} -> work_id end)

    identifiers = local_identifier_index(file_bearing)
    uncached_count = Enum.count(file_bearing, &(not Map.has_key?(identifiers, &1.foreign_id)))
    remaining = max(uncached_count - Books.max_bibliography_candidates(), 0)

    deferred =
      snapshot
      |> Map.get(:works, [])
      |> Enum.count(&(&1.monitored and not MapSet.member?(file_bearing_ids, &1.provider_id)))

    %{remaining: remaining, deferred_bibliography_count: deferred}
  end

  defp files_by_work(snapshot) do
    snapshot
    |> Map.get(:files, [])
    |> Enum.filter(&(&1.kind == :book and Map.has_key?(&1, :work_id)))
    |> Enum.group_by(& &1.work_id)
  end

  defp file_bearing_works(snapshot, files_by_work) do
    Enum.filter(Map.get(snapshot, :works, []), &Map.has_key?(files_by_work, &1.provider_id))
  end

  defp local_identifier_index([]), do: %{}

  defp local_identifier_index(works) do
    case works |> Enum.map(& &1.foreign_id) |> Enum.reject(&is_nil/1) do
      [] ->
        %{}

      foreign_ids ->
        Repo.all(
          from i in Identifier,
            where: i.provider == "readarr" and i.kind == "work" and i.foreign_id in ^foreign_ids,
            select: {i.foreign_id, i.work_id}
        )
        |> Map.new()
    end
  end

  # Free-text query for `Identity.resolve/1`: the resolved author's own name (the work carries
  # only `author_id`, not Bookshelf's raw `authorTitle`) plus the work's title. Author name
  # first, title second — mirroring the plan's literal `authorTitle <> title` order, which
  # matters for `Identity.select/2`'s left-to-right contributor-token subtraction: putting the
  # author tokens at the front means they are always consumed from the query's own leading edge,
  # never accidentally eaten out of the title.
  defp resolve(work, authors_by_id) do
    author_name =
      case Map.get(authors_by_id, work.author_id) do
        %{name: name} -> name
        _missing -> nil
      end

    query = [author_name, work.title] |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" ")

    Identity.resolve(query)
  end

  # Bulk-resolves every successfully-identified work's provider reference to an existing Cinder
  # `Books.Work` id (one batched query, `Books.work_ids_by_reference/1` — the same function
  # `drop_locally_monitored/1` uses) and folds resolve failures into the visible `:blocked`
  # candidate the plan requires instead of a silent drop.
  defp resolved_identity_map(resolutions) do
    refs =
      resolutions
      |> Enum.flat_map(fn
        {_id, {:ok, resolution}} -> [{resolution.provider, resolution.work.foreign_id}]
        {_id, _other} -> []
      end)
      |> Enum.uniq()

    work_ids = Books.work_ids_by_reference(refs)

    Map.new(resolutions, fn
      {provider_id, {:ok, resolution}} ->
        cinder_work_id =
          Map.get(work_ids, {to_string(resolution.provider), resolution.work.foreign_id})

        {provider_id, {:resolved, cinder_work_id, resolution}}

      {provider_id, {:unresolved, reason}} ->
        {provider_id, {:blocked, {:unresolved_identity, reason}}}

      {provider_id, {:error, reason}} ->
        {provider_id, {:blocked, {:unresolved_identity, reason}}}
    end)
  end

  defp catalog_state(identity_by_provider_id, files_by_work) do
    work_ids =
      identity_by_provider_id
      |> Map.values()
      |> Enum.flat_map(fn
        {:blocked, _reason} -> []
        identity -> [cinder_work_id(identity)]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    targets = targets_by_work_id(work_ids)
    target_ids = targets |> Map.values() |> Enum.map(& &1.id)

    all_paths =
      identity_by_provider_id
      |> Map.keys()
      |> Enum.flat_map(&Map.get(files_by_work, &1, []))
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    %{
      targets: targets,
      target_paths: target_file_paths(target_ids),
      path_owners: path_owners(all_paths),
      edition_index: edition_identifier_index(work_ids)
    }
  end

  defp cinder_work_id({:cached, work_id}), do: work_id
  defp cinder_work_id({:resolved, work_id, _resolution}), do: work_id

  defp targets_by_work_id([]), do: %{}

  defp targets_by_work_id(work_ids) do
    Repo.all(from t in BookTarget, where: t.work_id in ^work_ids and t.media_kind == :ebook)
    |> Map.new(&{&1.work_id, &1})
  end

  defp target_file_paths([]), do: %{}

  defp target_file_paths(target_ids) do
    Repo.all(
      from f in BookFile,
        where: f.book_target_id in ^target_ids,
        select: {f.book_target_id, f.path}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # A bulk query mirroring `MigrationAdoption.managed_state/1`, adapted to `BookFile`/
  # `BookTarget`: every existing owner (any work, any media kind) of any path this batch's
  # winning files might claim, in one round trip rather than one query per candidate.
  defp path_owners([]), do: %{}

  defp path_owners(paths) do
    Repo.all(
      from f in BookFile,
        join: t in BookTarget,
        on: t.id == f.book_target_id,
        where: f.path in ^paths,
        select: {f.path, t.work_id}
    )
    |> Map.new()
  end

  # `%{work_id => %{normalized_isbn_or_asin => cinder_edition_id}}`, scoped per resolved work so
  # one batch never lets a coincidental identifier collision leak an edition match from a
  # different resolved work in the same call.
  defp edition_identifier_index([]), do: %{}

  defp edition_identifier_index(work_ids) do
    Repo.all(
      from e in Edition,
        join: i in Identifier,
        on: i.edition_id == e.id and i.provider in ["isbn", "asin"],
        where: e.work_id in ^work_ids,
        select: {e.work_id, i.foreign_id, e.id}
    )
    |> Enum.group_by(&elem(&1, 0), fn {_work_id, foreign_id, edition_id} ->
      {foreign_id, edition_id}
    end)
    |> Map.new(fn {work_id, pairs} -> {work_id, Map.new(pairs)} end)
  end

  defp candidate(work, {:blocked, reason} = _identity, _files, _editions, _catalog) do
    Map.merge(base_candidate(work), %{
      status: :blocked,
      reason: reason,
      work_id: nil,
      identity: nil,
      edition_id: nil,
      path: nil,
      size: nil,
      primary_file: nil,
      extra_files: [],
      unsupported_files: []
    })
  end

  defp candidate(work, identity, files, provider_editions, catalog) do
    work_id = cinder_work_id(identity)
    target = Map.get(catalog.targets, work_id)
    target_paths = if target, do: Map.get(catalog.target_paths, target.id, []), else: []
    {accepted, unsupported} = Enum.split_with(files, &accepted_format?/1)

    base_candidate(work)
    |> Map.merge(%{
      work_id: work_id,
      identity: identity_evidence(work, identity),
      edition_id: edition_id_for(provider_editions, work_id, catalog.edition_index),
      unsupported_files: unsupported
    })
    |> Map.merge(classify_files(accepted, work_id, target, target_paths, catalog.path_owners))
  end

  defp base_candidate(work) do
    %{
      key: "book:#{work.provider_id}",
      kind: :book,
      provider_id: work.provider_id,
      author_id: work.author_id,
      source: :readarr,
      title: work.title,
      monitored: work.monitored
    }
  end

  defp identity_evidence(work, {:cached, _work_id}),
    do: %{provider: :readarr, foreign_id: work.foreign_id}

  defp identity_evidence(_work, {:resolved, _work_id, resolution}),
    do: %{provider: resolution.provider, foreign_id: resolution.work.foreign_id}

  defp accepted_format?(%{format: format}), do: format in @accepted_formats

  # No accepted-format file remains — nothing here is adoptable, so the work itself blocks. The
  # per-file evidence still rides along in `unsupported_files` (merged by the caller).
  defp classify_files([], _work_id, _target, _target_paths, _path_owners) do
    %{
      status: :blocked,
      reason: :unsupported_format,
      path: nil,
      size: nil,
      primary_file: nil,
      extra_files: []
    }
  end

  # Exactly one accepted-format file: classify it through the same cond chain
  # `movie_candidate/4`/`episode_file_status/3` use, in the order the plan's §3 bullets give.
  defp classify_files([file], work_id, target, target_paths, path_owners) do
    {status, reason} = winner_status(file, work_id, target, target_paths, path_owners)

    %{
      status: status,
      reason: reason,
      path: file.path,
      size: file.size,
      primary_file: nil,
      extra_files: []
    }
  end

  # More than one accepted-format file: `:needs_decision, :multi_format`. `primary_file`/
  # `extra_files` mirror Sonarr's n-to-one candidate shape exactly (`n_to_one_candidate/5`) —
  # B6c's adopt step reads `primary_file` alone for the **preferred** choice (EPUB, else AZW3,
  # else MOBI — `@accepted_formats`' own order) or `primary_file` + `extra_files` for **all**.
  # B6b only exposes the shape; no choice is applied here.
  defp classify_files(files, _work_id, _target, _target_paths, _path_owners) do
    primary =
      Enum.min_by(files, fn file -> Enum.find_index(@accepted_formats, &(&1 == file.format)) end)

    extras = Enum.reject(files, &(&1.provider_id == primary.provider_id))

    %{
      status: :needs_decision,
      reason: :multi_format,
      path: primary.path,
      size: primary.size,
      primary_file: primary,
      extra_files: extras
    }
  end

  defp winner_status(file, work_id, target, target_paths, path_owners) do
    cond do
      file.path in target_paths ->
        {:already_managed, nil}

      Map.get(path_owners, file.path) not in [nil, work_id] ->
        {:blocked, :path_conflict}

      target_paths != [] ->
        {:blocked, :identity_conflict}

      not is_nil(target) and target.status == :held ->
        {:blocked, :target_held}

      outside_library_root?(file.path) ->
        {:blocked, :outside_library_root}

      true ->
        {:ready, nil}
    end
  end

  # Kind-scoped to `:ebook` — `Settings.library_root_for_path/1` (any kind) would let a
  # translated path that lands inside the operator's movies/TV/audiobooks root pass as "inside
  # a library", the classic symptom of a misconfigured `readarr_local_path_prefix`. That is
  # exactly the misconfiguration this bucket exists to catch, so the check must be scoped to the
  # books root alone. See §0.2 of the B6 plan (corrected alongside this fix).
  defp outside_library_root?(path),
    do: match?({:error, :outside_library}, Settings.library_destination_for_path(:ebook, path))

  defp edition_id_for(_provider_editions, nil, _edition_index), do: nil

  defp edition_id_for(provider_editions, work_id, edition_index) do
    identifiers = Map.get(edition_index, work_id, %{})

    provider_editions
    |> Enum.flat_map(&[normalize_identifier(&1.isbn13), normalize_identifier(&1.asin)])
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&Map.get(identifiers, &1))
  end

  # Mirrors `Cinder.Books`'s own private `normalize_identifier/1` (the same rule
  # `put_normalized_identifier/4` stores every ISBN/ASIN `book_identifiers` row under) —
  # duplicated rather than exposed publicly for this one call site, since it is a stable,
  # two-line rule with nothing else to share.
  defp normalize_identifier(value) when is_binary(value) do
    case value |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identifier(_value), do: nil
end
