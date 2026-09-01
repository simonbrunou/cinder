defmodule Cinder.Books do
  @moduledoc """
  The provider-neutral books catalog and per-media-kind monitoring targets.

  Discovery search is separate from `Cinder.Books.Identity.resolve/1`: identity authorizes a
  grab by returning one work or refusing, while a search grid must expose the candidates.
  """

  import Ecto.Query

  require Logger

  alias Cinder.Books.{
    Author,
    BookBlockedRelease,
    BookFile,
    BookGrab,
    BookTarget,
    BookTargetTransition,
    Credit,
    Edition,
    Identifier,
    Metadata,
    SeriesMembership,
    Work
  }

  alias Cinder.Catalog.Profile
  alias Cinder.HTTPPolicy
  alias Cinder.LibraryKind
  alias Cinder.Repo

  @book_media_kinds LibraryKind.books()
  @targets_topic "book_targets"
  @work_preloads [
    :identifiers,
    :series_memberships,
    :targets,
    credits: [:author],
    editions: [:identifiers, credits: [:author]]
  ]

  @doc """
  Searches the configured metadata providers in order, stopping at the first non-empty answer.

  Results are not merged across providers: each owns its relevance order, and interleaving them
  would invent an unvalidated third ranking.
  """
  @spec search(String.t()) :: {:ok, [Metadata.candidate()]} | {:error, :providers_unavailable}
  def search(query), do: search_providers(Metadata.providers(), query, false)

  @spec work_ids_by_reference([{atom() | String.t(), String.t()}]) ::
          %{{String.t(), String.t()} => integer()}
  def work_ids_by_reference([]), do: %{}

  def work_ids_by_reference(references) do
    filter =
      Enum.reduce(references, dynamic(false), fn {provider, foreign_id}, filter ->
        provider = to_string(provider)

        dynamic(
          [identifier],
          ^filter or
            (identifier.provider == ^provider and identifier.foreign_id == ^foreign_id)
        )
      end)

    Repo.all(
      from identifier in Identifier,
        where: identifier.kind == "work",
        where: ^filter,
        select: {{identifier.provider, identifier.foreign_id}, identifier.work_id}
    )
    |> Map.new()
  end

  defp search_providers([], _query, true), do: {:ok, []}
  defp search_providers([], _query, false), do: {:error, :providers_unavailable}

  defp search_providers([provider_module | rest], query, answered?) do
    case provider_module.search(query) do
      {:ok, []} ->
        search_providers(rest, query, true)

      {:ok, candidates} ->
        {:ok, candidates}

      {:error, reason} ->
        Logger.info("books search: #{inspect(provider_module)} unavailable: #{inspect(reason)}")
        search_providers(rest, query, answered?)
    end
  end

  def upsert_author(attrs),
    do: upsert_by_identifier(Author, :author_id, %Author{}, attrs, &Author.changeset/2)

  def upsert_work(attrs),
    do: upsert_by_identifier(Work, :work_id, %Work{}, attrs, &Work.changeset/2)

  def upsert_edition(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:work_id, nil)
    work_id = Map.fetch!(attrs, :work_id)

    upsert_by_identifier(
      Edition,
      :edition_id,
      %Edition{work_id: work_id},
      attrs,
      &Edition.changeset/2
    )
  end

  def put_identifier(%Author{id: id}, attrs),
    do: insert_identifier(%Identifier{author_id: id}, attrs)

  def put_identifier(%Work{id: id}, attrs),
    do: insert_identifier(%Identifier{work_id: id}, attrs)

  def put_identifier(%Edition{id: id}, attrs),
    do: insert_identifier(%Identifier{edition_id: id}, attrs)

  def put_credit(%Work{id: id}, attrs),
    do: insert_credit(%Credit{work_id: id}, attrs)

  def put_credit(%Edition{id: id}, attrs),
    do: insert_credit(%Credit{edition_id: id}, attrs)

  def put_series_membership(%Work{id: id}, attrs) do
    attrs = Map.new(attrs)

    %SeriesMembership{work_id: id}
    |> SeriesMembership.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a work with identifiers, ordered credits and their authors, series memberships,
  targets, and editions with their own identifiers and ordered credits/authors preloaded.
  """
  def get_work(id) do
    case Repo.get(Work, id) do
      nil -> nil
      work -> Repo.preload(work, @work_preloads)
    end
  end

  def list_targets(%Work{id: id}) do
    Repo.all(from t in BookTarget, where: t.work_id == ^id, order_by: [asc: t.media_kind])
  end

  @doc """
  Every book target, work + credits + author preloaded — the `/library` books tab's row source.
  Ordered `desc: :id`, matching `Catalog.list_movies/0`'s "recently added" default. No status
  filter, for the same reason `list_movies/0` has none: a `:monitored`/`:held`/`:unmonitored`
  target is as much a managed row on that tab as an `:available` one is.
  """
  @spec list_targets() :: [BookTarget.t()]
  def list_targets do
    Repo.all(from t in BookTarget, order_by: [desc: t.id], preload: [work: [credits: :author]])
  end

  @doc """
  Bytes on disk per target, summed across its `book_files` rows and keyed by `book_target_id` —
  the `/library` books tab's size sort and size display. Mirrors
  `Catalog.SeriesCatalog.series_library_sizes/0`'s per-key SQL-sum shape: one aggregate query,
  not N+1 per row.
  """
  @spec target_sizes() :: %{integer() => integer()}
  def target_sizes do
    from(f in BookFile, group_by: f.book_target_id, select: {f.book_target_id, sum(f.size)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "One target by id, with its work and author credits preloaded, or nil."
  @spec get_target(integer()) :: BookTarget.t() | nil
  def get_target(id),
    do: Repo.one(from t in BookTarget, where: t.id == ^id, preload: [work: [credits: :author]])

  @doc """
  Target statuses for `work_ids`, keyed `{work_id, media_kind}` — the badge lookup, without the
  full work preload a badge has no use for.
  """
  @spec target_statuses([integer()]) :: %{{integer(), atom()} => atom()}
  def target_statuses([]), do: %{}

  def target_statuses(work_ids) do
    Repo.all(
      from t in BookTarget,
        where: t.work_id in ^work_ids,
        select: {{t.work_id, t.media_kind}, t.status}
    )
    |> Map.new()
  end

  def ensure_target(%Work{id: id}, media_kind) when media_kind in @book_media_kinds do
    result =
      %BookTarget{work_id: id}
      |> BookTarget.create_changeset(%{media_kind: media_kind})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:work_id, :media_kind])

    case result do
      {:ok, _target} -> {:ok, Repo.get_by!(BookTarget, work_id: id, media_kind: media_kind)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def transition_target(%BookTarget{} = target, attrs, opts) do
    {expected, opts} = Keyword.pop!(opts, :expect)
    BookTargetTransition.guarded(target, attrs, expected, opts)
  end

  @doc """
  Parks `target` `:held` with an operator-readable `reason`.

  The one place the acquisition pipeline gives up on a target. Both halves route through it —
  `Cinder.Download` when a submission is permanently rejected, `Cinder.Download.BookPoller` when
  a download dies or a payload is refused — so a failure is never left as a `:monitored` target
  with nothing in flight. That state is indistinguishable from "nobody has picked a release yet",
  and this slice has no search sweep to look at it again, so a silent failure would be permanent.

  Guarded on `:monitored`: anything else is a more recent decision than this one — an operator
  unmonitored it, someone already held it, or an import landed — and it stands.

  `opts[:replace]` (default `false`) widens the guard to `[:monitored, :available]`. A "Find a
  better match" grab's target is `:available` for its whole download/import cycle — grabs never
  touch `book_targets.status` (see `pause_target/1`'s doc) — so a replace grab's own failure
  paths (`Download.abandon_reserved/2`, `BookPoller.hold_orphaned_target/4`,
  `BookPoller.hold/3`) must be able to park an `:available` target, not just a `:monitored` one.
  A plain (non-replace) grab's target is `:monitored` for its entire cycle by construction — a
  fresh grab is only ever created for a `:monitored` target — so the guard still refuses to hold
  one that reached `:available` some other way.

  `release_title` (default `nil`) is the release that caused the hold, if one exists (a
  submission rejection or a download/import failure always has one; an orphaned-target hold does
  not). Only on `{:ok, held}`, and only when present, a best-effort `BookBlockedRelease` row
  follows the commit — non-transactional, after commit, log-and-swallow on failure — so the next
  manual search or "Find a better match" does not re-offer the same dead release.

  `transient` (default `false`) records whether this hold is worth an unattended retry later
  (`Cinder.Books.Rehunter`) — a fact the caller states explicitly, since `hold_reason` is free
  text with no closed vocabulary to infer it from.
  """
  @spec hold_target(BookTarget.t(), term(), String.t() | nil, boolean(), keyword()) ::
          {:ok, BookTarget.t()} | {:error, term()}
  def hold_target(
        %BookTarget{} = target,
        reason,
        release_title \\ nil,
        transient \\ false,
        opts \\ []
      ) do
    expected =
      if Keyword.get(opts, :replace, false), do: [:monitored, :available], else: :monitored

    target
    |> transition_target(
      %{status: :held, hold_reason: hold_reason(reason), hold_transient: transient},
      expect: expected
    )
    |> tap_block_release(release_title, reason)
  end

  defp tap_block_release({:ok, held} = ok, release_title, reason) do
    maybe_block_release(held, release_title, reason)
    ok
  end

  defp tap_block_release(error, _release_title, _reason), do: error

  defp maybe_block_release(_held, nil, _reason), do: :ok

  defp maybe_block_release(%BookTarget{id: id}, release_title, reason) do
    attrs = %{book_target_id: id, release_title: release_title, reason: hold_reason(reason)}

    case %BookBlockedRelease{} |> BookBlockedRelease.changeset(attrs) |> Repo.insert() do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "book block_release failed for #{inspect(attrs)}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  catch
    kind, value ->
      Logger.warning("book block_release raised: #{inspect({kind, value})}")
      :ok
  end

  @doc "Downcased-or-not release titles blocked for `target_id` (the exact strings stored)."
  @spec blocked_release_titles(integer()) :: [String.t()]
  def blocked_release_titles(target_id) do
    Repo.all(
      from b in BookBlockedRelease,
        where: b.book_target_id == ^target_id,
        select: b.release_title
    )
  end

  @doc """
  Deletes every blocklist row for `target_id`. No status write, no broadcast — mirrors
  `Catalog.clear_stalled_blocklist/1`'s "no side effect" contract.
  """
  @spec clear_blocklist(integer()) :: :ok
  def clear_blocklist(target_id) do
    Repo.delete_all(from b in BookBlockedRelease, where: b.book_target_id == ^target_id)
    :ok
  end

  @doc """
  Returns a `:held` target to `:monitored` for a human to pick a different release.

  Deliberately does NOT clear the blocklist: the dead release staying blocklisted is what stops
  the very next search from re-offering it.
  """
  @spec retry_target(BookTarget.t()) :: {:ok, BookTarget.t()} | {:error, term()}
  def retry_target(%BookTarget{} = target),
    do: transition_target(target, %{status: :monitored}, expect: :held)

  @doc """
  Pauses a `:monitored` target to `:unmonitored`.

  Not a plain guarded transition: a grab never changes `book_targets.status`, so an unguarded
  transition could pause a target mid-download. If the download then completed,
  `Files.record_import/3`'s `arm_target/1` guard would match neither `:monitored` nor
  `:available`, rolling the import back — and `BookPoller.do_import_one/2`'s `:stale_status`
  clause just deletes the grab and returns `:ok`, silently losing an already-downloaded file.

  The status transition and a `book_grabs` non-existence check run inside one
  `Repo.transaction/1`, refusing with `{:error, :grab_in_progress}` if a grab for the target
  exists — closing the race rather than narrowing it.
  """
  @spec pause_target(BookTarget.t()) ::
          {:ok, BookTarget.t()} | {:error, :grab_in_progress | :stale_status}
  def pause_target(%BookTarget{id: id}) do
    Repo.transaction(fn ->
      if Repo.exists?(from g in BookGrab, where: g.book_target_id == ^id),
        do: Repo.rollback(:grab_in_progress),
        else: do_pause(id)
    end)
    |> publish_pause()
  end

  defp do_pause(id) do
    case Repo.update_all(
           from(t in BookTarget, where: t.id == ^id and t.status == :monitored, select: t),
           set: [status: :unmonitored, updated_at: DateTime.utc_now(:second)]
         ) do
      {1, [updated]} -> updated
      {0, _none} -> Repo.rollback(:stale_status)
    end
  end

  defp publish_pause({:ok, target}) do
    broadcast({:book_target_updated, target})
    {:ok, target}
  end

  defp publish_pause(error), do: error

  @doc """
  Resumes an `:unmonitored` target to `:monitored`. `profile_id` is untouched — it was set at
  approval and pausing never clears it, so resume needs no profile re-selection.
  """
  @spec resume_target(BookTarget.t()) :: {:ok, BookTarget.t()} | {:error, term()}
  def resume_target(%BookTarget{} = target),
    do: transition_target(target, %{status: :monitored}, expect: :unmonitored)

  # `inspect/1`, never `to_string/1`: a reason may be a tuple (`{:unexpected_destination_type,
  # :directory}`), and `String.Chars` is undefined for tuples — `to_string/1` raised inside the
  # hold, the poller's `isolate/2` swallowed it, and the grab neither held nor cleared.
  #
  # Remote strings get sanitized rather than inspected. A download client's own error text and a
  # blocked filename are attacker-influenced and unbounded, and `hold_reason` is both persisted
  # and read by a household member: `inspect/1` would show them quoted and full-length, while
  # `sanitize_log/1` strips CRLF and truncates — the same treatment every other remote string in
  # the pollers already gets.
  defp hold_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp hold_reason(reason) when is_binary(reason), do: HTTPPolicy.sanitize_log(reason)

  defp hold_reason({code, detail}) when is_atom(code) and is_binary(detail),
    do: "#{code}: #{HTTPPolicy.sanitize_log(detail)}"

  defp hold_reason(reason), do: inspect(reason)

  @doc """
  The approval choke-point: ensures `work` has a `media_kind` target, attaches `profile`, and
  arms it — in one guarded write, so one broadcast.

  Only `:unmonitored` advances to `:monitored`. `:available` must not be downgraded, so a second
  requester approving an already-satisfied work takes the profile and leaves the status alone.

  A `:held` target is refused outright with `{:error, :target_held}`. Holding is the contract's
  operator-visible identity/disk/import conflict and is operator-cleared, so silently approving
  onto one would flip the request to approved and tell the requester Cinder is looking for a
  copy while nothing ever searches. The admin has to clear the hold first.

  Pass `publish: false` when calling inside a transaction and broadcast
  `{:book_target_updated, target}` yourself after commit.

  The kind check is here rather than in `BookTarget.transition_changeset/2` because that
  changeset has no `%Profile{}` to inspect. `book_targets_profile_integrity_update` is the DB
  fence behind it, but it fires under `update_all`, which raises rather than returning a
  changeset — so a mismatch is refused before the write, not caught after it.
  """
  def monitor_target(work, media_kind, profile, opts \\ [])

  def monitor_target(%Work{} = work, media_kind, %Profile{kind: kind} = profile, opts)
      when kind == media_kind do
    with {:ok, target} <- ensure_target(work, media_kind) do
      arm(target, profile, opts)
    end
  end

  def monitor_target(%Work{}, _media_kind, %Profile{}, _opts),
    do: {:error, :invalid_media_profile}

  defp arm(%BookTarget{status: :held}, _profile, _opts), do: {:error, :target_held}

  defp arm(%BookTarget{status: status} = target, profile, opts) do
    next = if status == :unmonitored, do: :monitored, else: status

    transition_target(
      target,
      %{status: next, profile_id: profile.id},
      Keyword.put(opts, :expect, status)
    )
  end

  @doc """
  Sets or clears an admin's language preference on a target, independent of the status pipeline
  — unlike `transition_target/3`/`arm/3`, this never touches `:status` and carries no `:expect`
  precondition, so it is safe to call regardless of where the target is in its lifecycle (armed,
  held, available — an admin may reasonably change their mind about language after the fact).
  `language` is `nil` for "no preference" or a code `BookTarget.language_changeset/2` recognizes
  (`Cinder.Acquisition.Parser.language_tags/0`); an unrecognized code — reachable only by a
  forged caller, since `/books/:id`'s own picker is built from that same table — refuses with
  `{:error, changeset}` rather than persisting it. Broadcasts `{:book_target_updated, target}`
  post-commit, matching every other write in this module.
  """
  @spec set_target_language(BookTarget.t(), String.t() | nil) ::
          {:ok, BookTarget.t()} | {:error, Ecto.Changeset.t()}
  def set_target_language(%BookTarget{} = target, language) do
    target
    |> BookTarget.language_changeset(%{preferred_language: language})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast({:book_target_updated, updated})
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc "Subscribes the caller to `{:book_target_updated, target}` broadcasts."
  def subscribe_targets, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @targets_topic)

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @targets_topic, message)

  @doc """
  Works with at least one monitoring target, identifiers preloaded — the refresh set.
  """
  def list_works_for_refresh do
    Repo.all(
      from w in Work,
        join: t in assoc(w, :targets),
        distinct: true,
        order_by: [asc: w.id],
        preload: [:identifiers]
    )
  end

  @doc """
  Folds a `Cinder.Books.Identity` resolution into the catalog in one transaction: the work and its
  provider identifier, each identified contributor as an author plus an ordered credit, the digital
  editions with their own identifiers and normalized ISBN/ASIN, and the series memberships.

  Idempotent. Everything is keyed off `book_identifiers`, so re-importing the same work — from the
  same provider, from the other one, or with a different ISBN in the payload — updates in place
  rather than duplicating.

  **Only fields the provider actually returned are written.** A payload missing `overview` leaves
  an existing overview alone instead of nilling it, which is what makes a partial or degraded
  provider response safe to import.

  Credits and series memberships follow the same rule at list granularity: a **non-empty** list
  replaces the stored rows wholesale, so they are exactly what the last successful import said
  rather than an accreted union of every provider that ever ran — while an **empty** list is read
  as "the provider said nothing" and leaves the stored rows alone. `OpenLibrary.get_work/1`
  reports `series: []` unconditionally and drops contributors whenever Open Library omits
  `author_key`, so without that reading a routine refresh would erase both.

  The cost is that an empty list and "genuinely none" are currently the same thing, so nothing can
  clear a credit or membership once stored. No caller needs to yet. When one does, the fix is for
  an adapter to distinguish the two — `series: nil` for "this provider does not report series"
  against `series: []` for "this work has none" — rather than to bring the wholesale wipe back.

  A contributor the provider named but did not identify is dropped, not invented, and the work is
  flagged `contributors_incomplete`.
  """
  def import_resolution(%{work: work, provider: provider}) do
    Repo.transaction(fn -> import_work(work, to_string(provider)) end, mode: :immediate)
  end

  defp import_work(work, provider) do
    {contributors, dropped?} = identified_contributors(work.contributors)

    attrs =
      %{
        title: work.title,
        first_published_on: work.first_published_on,
        overview: work.overview,
        contributors_incomplete: work.contributors_incomplete or dropped?
      }
      |> drop_nils()
      |> Map.put(:identifier, %{provider: provider, kind: "work", foreign_id: work.foreign_id})

    record = upsert_in_tx(Work, :work_id, %Work{}, attrs, &Work.changeset/2)

    put_credits(record, contributors, provider)
    put_series(record, work.series, provider)
    Enum.each(work.editions, &put_edition(record, &1, provider))

    record
  end

  # A contributor with no provider id cannot be identified across refreshes, and the contract
  # forbids inventing one. Drop it and let `contributors_incomplete` carry the signal.
  # `dropped?` is measured before deduplicating: Open Library's parallel author arrays repeat a
  # key for works with duplicated author entries, and a repeat is not a missing contributor.
  # Comparing against the post-dedup length would flag those works for operator review over
  # nothing.
  defp identified_contributors(contributors) do
    identified = Enum.filter(contributors, &present?(&1.foreign_id))

    {Enum.uniq_by(identified, &{&1.foreign_id, &1.role}),
     length(identified) != length(contributors)}
  end

  # An empty list is "the provider said nothing", not "the provider said none" — the same rule
  # `drop_nils/1` applies to scalars. Open Library omits `author_key` for works with no linked
  # author record, and author merges change that over time, so replacing wholesale would let one
  # such response wipe every stored credit.
  defp put_credits(_work, [], _provider), do: :ok

  defp put_credits(work, contributors, provider) do
    Repo.delete_all(from c in Credit, where: c.work_id == ^work.id)

    contributors
    |> Enum.with_index()
    |> Enum.each(fn {contributor, position} ->
      author =
        upsert_in_tx(
          Author,
          :author_id,
          %Author{},
          %{
            name: contributor.name,
            identifier: %{
              provider: provider,
              kind: "author",
              foreign_id: contributor.foreign_id
            }
          },
          &Author.changeset/2
        )

      work
      |> put_credit(%{author_id: author.id, role: contributor.role, position: position})
      |> or_rollback()
    end)
  end

  # Same rule as `put_credits/3`, and it matters more here: `OpenLibrary.get_work/1` always
  # reports `series: []` because the search document carries none, so without this every refresh
  # of an OL-identified work would clear memberships another provider had established.
  defp put_series(_work, [], _provider), do: :ok

  defp put_series(work, series, provider) do
    Repo.delete_all(from m in SeriesMembership, where: m.work_id == ^work.id)

    series
    |> Enum.uniq_by(& &1.name)
    |> Enum.each(fn entry ->
      work
      |> put_series_membership(%{name: entry.name, position: entry.position, provider: provider})
      |> or_rollback()
    end)
  end

  defp put_edition(work, edition, provider) do
    attrs =
      %{
        media_kind: edition.media_kind,
        title: edition.title,
        language: edition.language,
        format: edition.format,
        publisher: edition.publisher,
        release_date: edition.release_date,
        abridged: edition.abridged
      }
      |> drop_nils()
      |> Map.merge(%{
        work_id: work.id,
        identifier: %{provider: provider, kind: "edition", foreign_id: edition.foreign_id}
      })

    record =
      upsert_in_tx(
        Edition,
        :edition_id,
        %Edition{work_id: work.id},
        attrs,
        &Edition.changeset/2
      )

    put_normalized_identifier(record, "isbn", "isbn13", edition.isbn13)
    put_normalized_identifier(record, "asin", "asin", edition.asin)
  end

  # ISBN/ASIN are stored normalized, so "978-1-4000-3341-6" and "9781400033416" are one identifier
  # rather than two rows nothing can join on.
  #
  # on_conflict: :nothing — an ISBN already recorded against a different edition keeps pointing
  # where it is. Re-pointing a normalized identifier is an identity change, and the contract wants
  # those backed by evidence, not by whichever provider ran last.
  defp put_normalized_identifier(edition, provider, kind, value) do
    case normalize_identifier(value) do
      nil ->
        :ok

      normalized ->
        insert_identifier(
          %Identifier{edition_id: edition.id},
          %{provider: provider, kind: kind, foreign_id: normalized},
          on_conflict: :nothing,
          conflict_target: [:provider, :kind, :foreign_id]
        )
    end
  end

  defp normalize_identifier(value) when is_binary(value) do
    case value |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identifier(_value), do: nil

  defp or_rollback({:ok, record}), do: record
  defp or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp drop_nils(attrs), do: Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Take the write lock before lookup so concurrent upserts cannot share a stale snapshot.
  defp upsert_by_identifier(schema, subject_key, initial, attrs, changeset_fun) do
    Repo.transaction(
      fn -> upsert_in_tx(schema, subject_key, initial, attrs, changeset_fun) end,
      mode: :immediate
    )
  end

  # The body of `upsert_by_identifier/5` without its transaction, so `import_resolution/1` can
  # fold a whole work — author, work, editions, identifiers — into one.
  defp upsert_in_tx(schema, subject_key, initial, attrs, changeset_fun) do
    attrs = Map.new(attrs)
    identifier_attrs = attrs |> Map.fetch!(:identifier) |> Map.new()

    case Repo.get_by(
           Identifier,
           provider: Map.fetch!(identifier_attrs, :provider),
           kind: Map.fetch!(identifier_attrs, :kind),
           foreign_id: Map.fetch!(identifier_attrs, :foreign_id)
         ) do
      nil -> insert_subject(initial, attrs, identifier_attrs, changeset_fun)
      identifier -> update_subject(schema, subject_key, identifier, attrs, changeset_fun)
    end
  end

  defp insert_subject(initial, attrs, identifier_attrs, changeset_fun) do
    with {:ok, subject} <- initial |> changeset_fun.(attrs) |> Repo.insert(),
         {:ok, _identifier} <- put_identifier(subject, identifier_attrs) do
      subject
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_subject(
         Edition,
         :edition_id,
         %{edition_id: id},
         %{work_id: work_id} = attrs,
         changeset_fun
       )
       when not is_nil(id) do
    case Repo.get!(Edition, id) do
      %Edition{work_id: ^work_id} = edition ->
        edition |> changeset_fun.(attrs) |> update_or_rollback()

      %Edition{} ->
        Repo.rollback(:identifier_subject_mismatch)
    end
  end

  defp update_subject(schema, subject_key, identifier, attrs, changeset_fun) do
    case Map.fetch!(identifier, subject_key) do
      nil -> Repo.rollback(:identifier_subject_mismatch)
      id -> schema |> Repo.get!(id) |> changeset_fun.(attrs) |> update_or_rollback()
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, subject} -> subject
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_identifier(identifier, attrs, opts \\ []) do
    identifier
    |> Identifier.changeset(Map.new(attrs))
    |> Repo.insert(opts)
  end

  defp insert_credit(%Credit{} = credit, attrs) do
    attrs = Map.new(attrs)

    %Credit{credit | author_id: Map.get(attrs, :author_id)}
    |> Credit.changeset(attrs)
    |> Repo.insert()
  end
end
