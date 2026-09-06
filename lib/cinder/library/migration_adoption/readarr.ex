defmodule Cinder.Library.MigrationAdoption.Readarr do
  @moduledoc """
  Bounded, cached e-book library classification for adopting Bookshelf's existing library —
  `docs/plans/2026-09-01-books-b6-migration-and-cutover.md` §B6b (`plan/2`, `summary/2`,
  preview-only) and §B6c (`revalidate/1`, `adopt/2`, the write path via `Cinder.Books.Adoption`).

  A sibling extraction from `Cinder.Library.MigrationAdoption`, the same "carved out as plain
  code motion" pattern `Cinder.Settings.Registry`/`Crypto` already established, not a new
  top-level namespace. `MigrationAdoption.plan_source/3`'s `:readarr` clause delegates straight
  to `plan/2` below; `MigrationAdoption.adopt/2`'s `:readarr` clause delegates to `revalidate/1`
  then `adopt/2`.

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
     `Cinder.Books.max_bibliography_candidates/0` per `plan/2` call. Beyond the cap, a work is
     simply not yet a candidate; its count surfaces through `summary/2`'s `:remaining`, exactly
     the field `preview_author_policy/2` already returns for the same reason.

  A work step 2 actually attempts — resolved or not — becomes a visible, explained candidate:
  `:blocked, {:unresolved_identity, reason}` on failure, classified by file below on success.
  This is what distinguishes `:blocked` from `:remaining` — `remaining` counts works the cap
  never reached this call, `:blocked` counts works the cap *did* reach where identity could not
  resolve one.

  ## Write boundary

  `plan/2` and `summary/2` perform **zero** database writes, matching `revalidate/1` (a fresh
  local classification, no Bookshelf refetch, no `Identity.resolve/1` call). `Identity.resolve/1`
  is already read-only (`get_work/1`, never `Cinder.Books.import_resolution/1`), and every other
  read here (`book_identifiers`, `book_targets`, `book_files`, `book_editions`) is a plain
  `Repo.all`/`Ecto` query, never an insert/update/delete. This is what makes "a dry run changes
  nothing" true by construction, not by a separate check. Only `adopt/2` writes, and only through
  `Cinder.Books.Adoption.adopt_work/3` — B6c's single choke-point.
  """

  import Ecto.Query

  alias Cinder.Acquisition.{AudiobookScorer, BookScorer}
  alias Cinder.Books
  alias Cinder.Books.Adoption, as: BooksAdoption
  alias Cinder.Books.{BookFile, BookTarget, Edition, Identifier}
  alias Cinder.Books.Identity
  alias Cinder.Books.Metadata
  alias Cinder.Library.MigrationSource
  alias Cinder.Repo
  alias Cinder.Settings

  # The parity contract's e-book and audiobook profiles, most preferred first within each —
  # reusing `BookScorer`'s/`AudiobookScorer`'s own lists rather than duplicating them, so the
  # release scorer and the migration classifier can never drift on what "accepted" means.
  # Combined for `accepted_format?/1`'s "is this file classifiable at all" gate; kept as two
  # separate lists for `media_kind_for/1`, which decides WHICH kind's target a classified file
  # belongs to (B7e — the Bookshelf audiobook instance reports `m4b`/`mp3`, not e-book formats).
  @ebook_formats Enum.map(BookScorer.accepted_formats(), &to_string/1)
  @audiobook_formats Enum.map(AudiobookScorer.accepted_formats(), &to_string/1)
  @accepted_formats @ebook_formats ++ @audiobook_formats

  # A file whose format resolves to neither kind stays `:unsupported_format`, exactly as before
  # this classifier existed — this only ever WIDENS which formats are recognized, never narrows.
  defp media_kind_for(format) when format in @ebook_formats, do: {:ok, :ebook}
  defp media_kind_for(format) when format in @audiobook_formats, do: {:ok, :audiobook}
  defp media_kind_for(_unrecognized), do: :error

  @doc """
  Classifies every file-bearing work in `snapshot`, minus `exclude`, into one `:readarr`
  candidate, mirroring `MigrationAdoption`'s `movie_candidate/4` cond-chain style. See the module
  doc and the B6b plan §3 for the classification rules.

  `exclude` (default `MapSet.new()`) is a set of `work.provider_id` values to drop before
  classification even starts — `MigrationAdoption.preview/2`'s `opts[:exclude]`, the LiveView's
  own batch accumulator (B6c) asking not to re-pay or re-emit a work an earlier batch in the same
  scan session already classified. `plan/2` has no cursor of its own; see the module doc's write
  boundary and `MigrationAdoption.preview/2`'s own doc for why the caller carries this instead.

  A monitored work with no file never reaches this function at all — see `summary/2`'s
  `:deferred_bibliography_count`.
  """
  @spec plan(MigrationSource.snapshot(), MapSet.t()) :: [map()]
  def plan(snapshot, exclude \\ MapSet.new()) do
    files_by_work = files_by_work(snapshot)

    file_bearing =
      snapshot
      |> file_bearing_works(files_by_work)
      |> Enum.reject(&MapSet.member?(exclude, &1.provider_id))

    identifiers = local_identifier_index(file_bearing)
    {cached, uncached} = Enum.split_with(file_bearing, &Map.has_key?(identifiers, &1.foreign_id))
    {to_resolve, _remaining} = Enum.split(uncached, Books.max_bibliography_candidates())

    authors_by_id = Map.new(Map.get(snapshot, :authors, []), &{&1.provider_id, &1})
    resolutions = Map.new(to_resolve, &{&1.provider_id, resolve(&1, authors_by_id)})
    editions_by_work = Enum.group_by(Map.get(snapshot, :editions, []), & &1.work_id)

    cached_identity =
      Map.new(cached, &{&1.provider_id, {:cached, Map.fetch!(identifiers, &1.foreign_id)}})

    identity_by_provider_id = Map.merge(cached_identity, resolved_identity_map(resolutions))

    work_ids = catalog_work_ids(identity_by_provider_id)
    all_paths = catalog_paths(identity_by_provider_id, files_by_work)
    catalog = catalog_state(work_ids, all_paths)

    (cached ++ to_resolve)
    |> Enum.map(fn work ->
      candidate(
        work,
        Map.fetch!(identity_by_provider_id, work.provider_id),
        Map.get(files_by_work, work.provider_id, []),
        Map.get(editions_by_work, work.provider_id, []),
        catalog,
        authors_by_id
      )
    end)
  end

  @doc """
  Preview summary fields no other migration source needs.

  `remaining` is how many not-yet-attempted works `plan/2`'s cap left this call — the identical
  field name and meaning `Books.preview_author_policy/2` already returns. `deferred_bibliography_count`
  is the count of monitored, fileless works (661 of the eBook instance's 842, in the real
  deployment) that never became candidates at all: importing every monitored source row as an
  active acquisition request would be the "back-catalogue flood" the parity contract's own
  cutover-hazard section warns against, so this is pure snapshot arithmetic, never a candidate.
  Unaffected by `exclude` — a fileless work is never a candidate in any batch, so there is nothing
  for a batch accumulator to have already counted.

  `exclude` (default `MapSet.new()`) mirrors `plan/2`'s own — the same batch accumulator, so
  `remaining` stays consistent with what THIS batch's `plan/2` call actually left unattempted.

  Both fields are cheap, local-DB-only reads — nothing here issues a metadata-provider HTTP
  request. This redoes `plan/2`'s local identifier-cache lookup once more (one extra indexed
  `book_identifiers` read per `MigrationAdoption.preview/2` call) rather than threading a second
  return value through `plan/4`'s list-returning contract every other migration source relies on
  unchanged — see `MigrationAdoption.extra_fields/3`.
  """
  @spec summary(MigrationSource.snapshot(), MapSet.t()) :: %{
          remaining: non_neg_integer(),
          deferred_bibliography_count: non_neg_integer(),
          deferred_bibliography_authors: [MigrationSource.provider_id()]
        }
  def summary(snapshot, exclude \\ MapSet.new()) do
    files_by_work = files_by_work(snapshot)
    file_bearing_ids = MapSet.new(files_by_work, fn {work_id, _files} -> work_id end)

    file_bearing =
      snapshot
      |> file_bearing_works(files_by_work)
      |> Enum.reject(&MapSet.member?(exclude, &1.provider_id))

    identifiers = local_identifier_index(file_bearing)
    uncached_count = Enum.count(file_bearing, &(not Map.has_key?(identifiers, &1.foreign_id)))
    remaining = max(uncached_count - Books.max_bibliography_candidates(), 0)

    fileless =
      snapshot
      |> Map.get(:works, [])
      |> Enum.filter(&(&1.monitored and not MapSet.member?(file_bearing_ids, &1.provider_id)))

    %{
      remaining: remaining,
      deferred_bibliography_count: length(fileless),
      deferred_bibliography_authors: Enum.uniq(for work <- fileless, do: work.author_id)
    }
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

  defp catalog_work_ids(identity_by_provider_id) do
    identity_by_provider_id
    |> Map.values()
    |> Enum.flat_map(fn
      {:blocked, _reason} -> []
      identity -> [cinder_work_id(identity)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp catalog_paths(identity_by_provider_id, files_by_work) do
    identity_by_provider_id
    |> Map.keys()
    |> Enum.flat_map(&Map.get(files_by_work, &1, []))
    |> Enum.map(& &1.path)
    |> Enum.uniq()
  end

  # Shared by `plan/2` (fed the whole batch's candidate identities/paths) and `revalidate/1`
  # (B6c — fed just the already-selected candidates' own `work_id`/paths, no snapshot at all).
  defp catalog_state(work_ids, paths) do
    targets = targets_by_work_id(work_ids)
    target_ids = targets |> Map.values() |> Enum.map(& &1.id)

    %{
      targets: targets,
      target_paths: target_file_paths(target_ids),
      path_owners: path_owners(paths),
      edition_index: edition_identifier_index(work_ids)
    }
  end

  defp cinder_work_id({:cached, work_id}), do: work_id
  defp cinder_work_id({:resolved, work_id, _resolution}), do: work_id

  defp targets_by_work_id([]), do: %{}

  # No `media_kind` filter (B7e — was `:ebook`-only): a candidate's target must be looked up
  # scoped to ITS OWN resolved kind (`target_for/3` below), never silently missing an existing
  # `:audiobook` target's hold/already-managed state because this fetch only ever saw `:ebook`
  # rows. Keyed by `{work_id, media_kind}` — a work can carry one target of each kind
  # (`book_targets`' own `[work_id, media_kind]` unique index), and `Map.new/2` would otherwise
  # silently keep only the last one seen for a plain `work_id` key.
  defp targets_by_work_id(work_ids) do
    Repo.all(from t in BookTarget, where: t.work_id in ^work_ids)
    |> Map.new(&{{&1.work_id, &1.media_kind}, &1})
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

  defp candidate(work, {:blocked, reason} = _identity, _files, _editions, _catalog, authors_by_id) do
    Map.merge(base_candidate(work, authors_by_id), %{
      status: :blocked,
      reason: reason,
      work_id: nil,
      identity: nil,
      media_kind: nil,
      edition_id: nil,
      path: nil,
      size: nil,
      primary_file: nil,
      extra_files: [],
      unsupported_files: []
    })
  end

  defp candidate(work, identity, files, provider_editions, catalog, authors_by_id) do
    work_id = cinder_work_id(identity)
    {accepted, unsupported} = Enum.split_with(files, &accepted_format?/1)
    media_kind = accepted_media_kind(accepted)
    target = target_for(work_id, media_kind, catalog)
    target_paths = target_paths(work_id, media_kind, catalog)

    base_candidate(work, authors_by_id)
    |> Map.merge(%{
      work_id: work_id,
      identity: identity_evidence(work, identity),
      edition_id: edition_id_for(provider_editions, work_id, catalog.edition_index),
      unsupported_files: unsupported
    })
    |> Map.merge(
      classify_files(accepted, work_id, media_kind, target, target_paths, catalog.path_owners)
    )
  end

  # The candidate's own resolved kind, from its first accepted file — a real, real-world
  # Bookshelf snapshot is always single-instance (one migration source config, §0.3 of the B7
  # plan), so every accepted file for one work is the same kind in practice; `nil` when there is
  # no accepted file at all (`classify_files/6`'s `[]` clause needs no target lookup either way).
  defp accepted_media_kind([]), do: nil

  defp accepted_media_kind([file | _rest]) do
    {:ok, kind} = media_kind_for(file.format)
    kind
  end

  defp base_candidate(work, authors_by_id) do
    %{
      key: "book:#{work.provider_id}",
      kind: :book,
      provider_id: work.provider_id,
      author_id: work.author_id,
      # The author's own display name, carried through for B6c's deferred-bibliography banner
      # (`CinderWeb.LibraryAdoptionLive.migration_deferred/1`) — an accessible label needs a
      # human-readable name, not the raw Bookshelf-local `author_id` alone.
      author_name: authors_by_id |> Map.get(work.author_id, %{}) |> Map.get(:name),
      source: :readarr,
      title: work.title,
      monitored: work.monitored,
      # Bookshelf's own foreign id for this work (`Cinder.Library.MigrationSource.work/0`'s
      # `foreign_id`) — namespace-distinct from `identity.foreign_id` above, which (for a
      # `:resolved` identity) is the METADATA provider's own id. B6c's `adopt/2` needs Bookshelf's
      # id specifically to stamp `book_identifiers{provider: "readarr", ...}`
      # (`Cinder.Books.Adoption.adopt_work/3`'s `:bookshelf_foreign_id`).
      foreign_id: work.foreign_id
    }
  end

  defp identity_evidence(work, {:cached, _work_id}),
    do: %{provider: :readarr, foreign_id: work.foreign_id}

  defp identity_evidence(_work, {:resolved, _work_id, resolution}),
    do: %{provider: resolution.provider, foreign_id: resolution.work.foreign_id}

  defp accepted_format?(%{format: format}), do: format in @accepted_formats

  # No accepted-format file remains — nothing here is adoptable, so the work itself blocks. The
  # per-file evidence still rides along in `unsupported_files` (merged by the caller).
  defp classify_files([], _work_id, media_kind, _target, _target_paths, _path_owners) do
    %{
      status: :blocked,
      reason: :unsupported_format,
      path: nil,
      size: nil,
      media_kind: media_kind,
      primary_file: nil,
      extra_files: []
    }
  end

  # Exactly one accepted-format file: classify it through the same cond chain
  # `movie_candidate/4`/`episode_file_status/3` use, in the order the plan's §3 bullets give.
  defp classify_files([file], work_id, media_kind, target, target_paths, path_owners) do
    {status, reason} = winner_status(file, work_id, media_kind, target, target_paths, path_owners)

    %{
      status: status,
      reason: reason,
      path: file.path,
      size: file.size,
      media_kind: media_kind,
      # Needed by B6c's `adopt/2` to build the single `BookFile` insert attrs
      # (`BookFile.changeset/2` requires `:format`) — the multi-format branch below already
      # carries it on `primary_file`/`extra_files`; this plain single-file branch previously
      # dropped it since B6b (preview-only) never needed it.
      format: file.format,
      primary_file: nil,
      extra_files: []
    }
  end

  # More than one accepted-format file. Evaluated through the SAME `winner_status/6` cond-chain
  # the single-file branch uses — but over EVERY accepted file, not just the primary. Mirrors
  # `MigrationAdoption.n_to_one_status/4`'s own "check every member's path" precedent
  # (`migration_adoption.ex`): `:target_held`/`:identity_conflict`/`:already_managed` are
  # target-scoped and would trip on any file alike, but `:path_conflict` and
  # `:outside_library_root` are PER-FILE — a clean primary EPUB with a sibling AZW3 that already
  # belongs to a different work's target (or sits outside the configured library root for this
  # candidate's kind) must still block the whole candidate. Checking the primary alone left that
  # conflict invisible: the candidate rendered as an ordinary `:needs_decision`, the write failed
  # silently at revalidation every time, and a re-preview reproduced the identical misleading row
  # forever (`classify_files/6` never re-evaluated the sibling). Only once every file clears
  # (`{:ready, nil}`) does the candidate actually reach `:needs_decision, :multi_format`.
  # `primary_file`/`extra_files` mirror Sonarr's n-to-one candidate shape exactly
  # (`n_to_one_candidate/5`) — B6c's adopt step reads `primary_file` alone for the **preferred**
  # choice (most-preferred-first within the candidate's own resolved kind — EPUB else AZW3 else
  # MOBI for `:ebook`, M4B else MP3 for `:audiobook`, `@accepted_formats`' own combined order) or
  # `primary_file` + `extra_files` for **all**.
  #
  # Multiple audiobook files sharing ONE format are sequential tracks of a single audiobook
  # (Bookshelf/Readarr split MP3 by chapter; M4B is one file per book), never alternative
  # editions the way a mixed EPUB/AZW3/MOBI set — or a genuinely mixed M4B+MP3 set — is. Treating
  # a track set as `:multi_format` let `:preferred` hand the catalog exactly one chapter as if it
  # were the complete book (#513). `track_set?/2` tells the two apart; `reason: :multi_track`
  # carries the distinction through to `files_for/2`, which adopts the whole set atomically
  # regardless of which bulk/individual choice fires — there is no valid "pick one" for a track
  # set, so neither choice is allowed to mean that.
  defp classify_files(files, work_id, media_kind, target, target_paths, path_owners) do
    primary =
      Enum.min_by(files, fn file -> Enum.find_index(@accepted_formats, &(&1 == file.format)) end)

    extras = Enum.reject(files, &(&1.provider_id == primary.provider_id))

    case blocking_status(
           [primary | extras],
           work_id,
           media_kind,
           target,
           target_paths,
           path_owners
         ) do
      {:ready, nil} ->
        %{
          status: :needs_decision,
          reason: multi_file_reason(files, media_kind),
          path: primary.path,
          size: primary.size,
          media_kind: media_kind,
          primary_file: primary,
          extra_files: extras
        }

      {status, reason} ->
        %{
          status: status,
          reason: reason,
          path: primary.path,
          size: primary.size,
          media_kind: media_kind,
          format: primary.format,
          primary_file: nil,
          extra_files: []
        }
    end
  end

  defp multi_file_reason(files, media_kind) do
    if track_set?(files, media_kind), do: :multi_track, else: :multi_format
  end

  # Same format, more than one file, audiobook: sequential tracks, not alternative formats. An
  # e-book never has this shape (Readarr/Bookshelf report one file per e-book format, never a
  # split single format), and a genuinely mixed-format audiobook set (M4B + MP3) is still a real
  # format choice, not a track set.
  defp track_set?(files, :audiobook), do: files |> Enum.uniq_by(& &1.format) |> length() == 1
  defp track_set?(_files, :ebook), do: false

  # The first non-`{:ready, nil}` verdict among `files`, in order — or `{:ready, nil}` when every
  # one of them clears.
  defp blocking_status(files, work_id, media_kind, target, target_paths, path_owners) do
    Enum.reduce_while(files, {:ready, nil}, fn file, _acc ->
      case winner_status(file, work_id, media_kind, target, target_paths, path_owners) do
        {:ready, nil} -> {:cont, {:ready, nil}}
        blocked -> {:halt, blocked}
      end
    end)
  end

  defp winner_status(file, work_id, media_kind, target, target_paths, path_owners) do
    cond do
      file.path in target_paths ->
        {:already_managed, nil}

      Map.get(path_owners, file.path) not in [nil, work_id] ->
        {:blocked, :path_conflict}

      target_paths != [] ->
        {:blocked, :identity_conflict}

      not is_nil(target) and target.status == :held ->
        {:blocked, :target_held}

      outside_library_root?(media_kind, file.path) ->
        {:blocked, :outside_library_root}

      true ->
        {:ready, nil}
    end
  end

  # Kind-scoped to the CANDIDATE'S OWN resolved kind (B7e — was hardcoded `:ebook`) —
  # `Settings.library_root_for_path/1` (any kind) would let a translated path that lands inside
  # the operator's movies/TV/whichever-other-books root pass as "inside a library", the classic
  # symptom of a misconfigured `readarr_local_path_prefix`. That is exactly the misconfiguration
  # this bucket exists to catch, so the check must be scoped to the ONE root this file's own
  # resolved format belongs in — the books root for an `:ebook` candidate, the audiobooks root
  # for an `:audiobook` one. See §0.2 of the B6 plan (corrected alongside the original fix).
  defp outside_library_root?(media_kind, path),
    do:
      match?({:error, :outside_library}, Settings.library_destination_for_path(media_kind, path))

  defp edition_id_for(_provider_editions, nil, _edition_index), do: nil

  defp edition_id_for(provider_editions, work_id, edition_index) do
    identifiers = Map.get(edition_index, work_id, %{})

    provider_editions
    |> Enum.flat_map(&[normalize_identifier(&1.isbn13), normalize_identifier(&1.asin)])
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&Map.get(identifiers, &1))
  end

  # ================================================================ B6c: adopt ===

  @doc """
  Re-validates already-`selected` `:readarr` candidates against CURRENT catalog state, right
  before adopting — the same "preview and adopt are not atomic with each other" defense
  `MigrationAdoption.revalidate_catalog/2`'s `:radarr`/`:sonarr` clauses give via
  `movie_path_status/3`/`episode_file_status/3`, reusing this module's own `winner_status/6`
  cond-chain rather than a second one.

  No Bookshelf refetch and no `Identity.resolve/1` call here — those only ever run at preview
  time (`plan/2`); a candidate that went stale between preview and adopt is reported, never
  silently re-resolved against a possibly-different provider answer.

  `selected` is `[{candidate, choice}]`, `choice` one of `nil` (plain `:ready`), `:preferred`, or
  `:all_formats`. Returns `{valid, stale}` in the same shape, matching `Enum.split_with/2` (and
  `MigrationAdoption.revalidate_catalog/2`'s other clauses) exactly.
  """
  @spec revalidate([{map(), atom() | nil}]) :: {[{map(), atom() | nil}], [{map(), atom() | nil}]}
  def revalidate(selected) do
    work_ids =
      selected
      |> Enum.map(fn {c, _choice} -> c.work_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    paths =
      selected
      |> Enum.flat_map(fn {c, choice} -> candidate_files(c, choice) end)
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    catalog = catalog_state(work_ids, paths)

    Enum.split_with(selected, fn {candidate, choice} -> current?(candidate, choice, catalog) end)
  end

  defp candidate_files(%{primary_file: %{} = primary, extra_files: extras}, :all_formats),
    do: [primary | extras]

  defp candidate_files(%{primary_file: %{} = primary}, _choice), do: [primary]

  defp candidate_files(%{path: path, size: size, format: format}, _choice)
       when not is_nil(path),
       do: [%{path: path, size: size, format: format}]

  defp candidate_files(_candidate, _choice), do: []

  defp current?(
         %{status: :ready, work_id: work_id, media_kind: media_kind, path: path},
         _choice,
         catalog
       ) do
    winner_status(
      %{path: path},
      work_id,
      media_kind,
      target_for(work_id, media_kind, catalog),
      target_paths(work_id, media_kind, catalog),
      catalog.path_owners
    ) ==
      {:ready, nil}
  end

  defp current?(
         %{status: :needs_decision, work_id: work_id, media_kind: media_kind} = candidate,
         choice,
         catalog
       ) do
    target = target_for(work_id, media_kind, catalog)
    target_paths = target_paths(work_id, media_kind, catalog)

    candidate
    |> candidate_files(choice)
    |> Enum.all?(
      &(winner_status(&1, work_id, media_kind, target, target_paths, catalog.path_owners) ==
          {:ready, nil})
    )
  end

  defp current?(_candidate, _choice, _catalog), do: false

  defp target_for(work_id, media_kind, catalog),
    do: Map.get(catalog.targets, {work_id, media_kind})

  defp target_paths(work_id, media_kind, catalog) do
    case target_for(work_id, media_kind, catalog) do
      nil -> []
      target -> Map.get(catalog.target_paths, target.id, [])
    end
  end

  @doc """
  Adopts each `{candidate, choice}` pair in `selected` via `Cinder.Books.Adoption.adopt_work/3`,
  folding results into `summary` (`MigrationAdoption.adopt/2`'s running
  `%{adopted:, skipped:, failures:, adopted_keys:, stale_keys:}` accumulator).

  `isolate`-style: one candidate's failure never aborts the batch, matching
  `Cinder.Books.apply_author_policy/4`'s established contract. Callers revalidate first
  (`revalidate/1`) — this function trusts every pair it receives is still current and re-resolves
  identity fresh via `Cinder.Books.Identity.resolve/1` for each (one direct-by-reference fetch,
  never a free-text search — see `resolution_for/1`), since B6b's classification never threads a
  full resolution payload through the candidate.
  """
  @spec adopt(map(), [{map(), atom() | nil}]) :: map()
  def adopt(summary, selected) do
    Enum.reduce(selected, summary, fn {candidate, choice}, acc ->
      adopt_candidate(acc, candidate, choice)
    end)
  end

  defp adopt_candidate(summary, candidate, choice) do
    with {:ok, resolution} <- resolution_for(candidate),
         resolution = Map.put(resolution, :bookshelf_foreign_id, candidate.foreign_id),
         files = files_for(candidate, choice),
         {:ok, _target} <- BooksAdoption.adopt_work(resolution, files, candidate.media_kind) do
      summary
      |> Map.update!(:adopted, &(&1 + 1))
      |> Map.update!(:adopted_keys, &(&1 ++ [candidate.key]))
    else
      {:error, reason} ->
        Map.update!(summary, :failures, &(&1 ++ [%{path: candidate.path, reason: reason}]))
    end
  rescue
    e ->
      Map.update!(summary, :failures, fn failures ->
        failures ++ [%{path: candidate.path, reason: {:exception, Exception.message(e)}}]
      end)
  catch
    kind, value ->
      Map.update!(summary, :failures, &(&1 ++ [%{path: candidate.path, reason: {kind, value}}]))
  end

  # A `:resolved` candidate already carries the metadata provider's own reference — one direct
  # `get_work/1` fetch, never a search (`Identity.reference_for/2`'s whole point). A `:cached`
  # candidate's `identity.provider` is the sentinel `:readarr` (Bookshelf's own namespace, not a
  # real `Cinder.Books.Metadata` provider) — its work is already imported, so this looks up that
  # SAME Cinder work's own best non-"readarr" identifier instead of guessing one.
  defp resolution_for(%{identity: %{provider: :readarr}, work_id: work_id})
       when not is_nil(work_id) do
    case non_readarr_reference(work_id) do
      {:ok, provider, foreign_id} ->
        Identity.resolve(Identity.reference_for(provider, foreign_id))

      :error ->
        {:error, :no_provider_identity}
    end
  end

  defp resolution_for(%{identity: %{provider: provider, foreign_id: foreign_id}}),
    do: Identity.resolve(Identity.reference_for(provider, foreign_id))

  defp resolution_for(_candidate), do: {:error, :no_provider_identity}

  defp non_readarr_reference(work_id) do
    Identifier
    |> where([i], i.work_id == ^work_id and i.kind == "work" and i.provider != "readarr")
    |> order_by([i], asc: i.id)
    |> Repo.all()
    |> List.first()
    |> case do
      nil ->
        :error

      %Identifier{provider: provider, foreign_id: foreign_id} ->
        with_provider_atom(provider, foreign_id)
    end
  end

  defp with_provider_atom(provider, foreign_id) do
    case provider_atom(provider) do
      nil -> :error
      atom -> {:ok, atom, foreign_id}
    end
  end

  defp provider_atom(provider) do
    Metadata.providers()
    |> Enum.find(&(to_string(&1.provider()) == provider))
    |> case do
      nil -> nil
      module -> module.provider()
    end
  end

  # A track set has no valid "pick one" — every choice adopts the complete set. Matched before
  # the generic :all_formats/:preferred clauses below, which stay exactly as they were for a
  # genuine multi-format (alternative-edition) candidate.
  defp files_for(
         %{
           primary_file: %{} = primary,
           extra_files: extras,
           reason: :multi_track,
           edition_id: edition_id
         },
         _choice
       ),
       do: Enum.map([primary | extras], &file_attrs(&1, edition_id))

  defp files_for(
         %{primary_file: %{} = primary, extra_files: extras, edition_id: edition_id},
         :all_formats
       ),
       do: Enum.map([primary | extras], &file_attrs(&1, edition_id))

  defp files_for(%{primary_file: %{} = primary, edition_id: edition_id}, _preferred),
    do: [file_attrs(primary, edition_id)]

  defp files_for(%{path: path, size: size, format: format, edition_id: edition_id}, _choice),
    do: [%{path: path, size: size, format: format, edition_id: edition_id}]

  defp file_attrs(%{path: path, size: size, format: format}, edition_id),
    do: %{path: path, size: size, format: format, edition_id: edition_id}

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
