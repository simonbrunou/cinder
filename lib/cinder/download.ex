defmodule Cinder.Download do
  @moduledoc """
  Hands a `:requested` movie off to the download client: search for the best
  release and add it, advancing `:requested → :searching → :downloading` (or
  `:no_match`). The background `Cinder.Download.Poller` then tracks it to
  `:downloaded`.

  The client is reached only through the `Cinder.Download.Client` behaviour,
  resolved per-release-protocol from config (`config :cinder, :download_clients`,
  a `%{protocol => module}` map) so tests use Mox mocks and never hit the network.
  Auto-triggered by `Cinder.Download.Poller`'s search sweep.
  """
  import Ecto.Query

  require Logger
  alias Cinder.{Acquisition, Books, Catalog, Repo, Settings, Vault}

  alias Cinder.Acquisition.{
    AnimePreferences,
    AudiobookRelease,
    EbookRelease,
    HouseholdPolicy,
    IndexerSource,
    Release
  }

  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog.{Grab, MediaProfile, Movie, MovieLifecycle}
  alias Cinder.Download.{GrabFailure, GrabReserve, Intent, IntentEpisode, PollerProgress}

  # The indexer source that fetches a link, by the source name an intent records.
  @fetch_sources %{"prowlarr" => IndexerSource.Prowlarr, "native" => IndexerSource.Native}

  @doc """
  The submission errors that drop a reservation for good; a book target is also held on them
  (`abandon_reserved/2`), and a movie in its search phase parks on them
  (`Cinder.Catalog.MovieLifecycle.record_failure/2`). An `:invalid_intent_release` from a movie
  intent an earlier grab stored never reaches that write-back: the pending-intent pass drops that
  result, and `start/1` goes on as for a movie with no intent instead of returning it (#1564).
  An `:invalid_intent_release` from a grab that call then makes is returned like any other
  result. For a TV release that
  neither an operator nor the upgrade sweep picked (an intent not `operator_initiated`), Cinder
  tries to block the release for its series on each of them but `:invalid_intent_release`
  (`abandon_reserved/2`).
  `CinderWeb.LiveHelpers.book_hold_reason/1` words each one.
  """
  @spec permanent_submission_errors() :: [atom()]
  def permanent_submission_errors, do: GrabFailure.permanent()

  @doc "Reserves a durable downloader operation before any external side effect."
  def reserve_intent(%{release: %Release{download_url: url} = release} = attrs)
      when is_binary(url) do
    mapping_snapshot = Map.get(attrs, :mapping_snapshot)
    release_policy_snapshot = Map.get(attrs, :release_policy_snapshot)

    cond do
      mapping_snapshot != release.mapping_snapshot ->
        {:error, :invalid_mapping_snapshot}

      release_policy_snapshot != release.release_policy_snapshot ->
        {:error, :invalid_release_evidence}

      true ->
        reserve_marked_intent(
          attrs,
          release,
          url,
          mapping_snapshot,
          release_policy_snapshot
        )
    end
  end

  def reserve_intent(%{release: %Release{}}), do: {:error, :unsupported_download_url}

  defp reserve_marked_intent(
         attrs,
         release,
         url,
         mapping_snapshot,
         release_policy_snapshot
       ) do
    release_attrs = %{
      "title" => release.title,
      "download_url_ciphertext" => url |> Vault.encrypt!() |> Base.encode64(),
      "download_url_origin" => release.download_url_origin
    }

    # The indexer that served the release (#1515, #1645): the block row `abandon_reserved/2` tries
    # to write on a refusal records its source and id, and a grab adopts the intent only for a
    # copy from the same indexer (`same_release?/2`). Each key is stored only when the release
    # holds a value of its type; `indexer_source/1` reads an intent with no source as Prowlarr's.
    release_attrs =
      release_attrs
      |> put_if("indexer_source", release.indexer_source, &is_binary/1)
      |> put_if("indexer_id", release.indexer_id, &is_integer/1)
      |> put_if("credentials_version", release.credentials_version, &is_integer/1)

    release_attrs =
      if Map.get(attrs, :operator_initiated, false),
        do: Map.put(release_attrs, "operator_initiated", true),
        else: release_attrs

    # The size survives a retry or a crash here, so the owner row can record it whenever it is
    # written (`Intent.release_size/1`, `Cinder.Download.GrabReserve`).
    release_attrs =
      if is_integer(release.size),
        do: Map.put(release_attrs, "size", release.size),
        else: release_attrs

    # Same shape as operator_initiated, and deliberately a SECOND flag: both the manual season
    # search and the upgrade sweep set operator_initiated (it is what lets an intent target
    # episodes that already have a file), so it cannot tell attended from unattended (#250).
    release_attrs =
      if Map.get(attrs, :arbitrate_at_import, false),
        do: Map.put(release_attrs, "arbitrate_at_import", true),
        else: release_attrs

    # A confirmed "Find a better match" grab, carried the same way — the release map is the only
    # part of an intent's reservation attrs that survives across ticks/crashes, so this has to
    # live there rather than in a caller-local opt.
    release_attrs =
      if Map.get(attrs, :replace, false),
        do: Map.put(release_attrs, "replace", true),
        else: release_attrs

    intent_attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: Map.fetch!(attrs, :kind),
      target_id: Map.fetch!(attrs, :target_id),
      episode_ids: Map.get(attrs, :episode_ids, []),
      protocol: Map.fetch!(attrs, :protocol),
      mapping_snapshot: mapping_snapshot,
      release_policy_snapshot: release_policy_snapshot,
      release: release_attrs,
      status: :reserved
    }

    Repo.transaction(fn -> insert_reserved_intent(intent_attrs) end)
    |> normalize_reservation()
  rescue
    Ecto.ConstraintError -> {:error, :download_intent_busy}
  end

  defp put_if(map, key, value, type?),
    do: if(type?.(value), do: Map.put(map, key, value), else: map)

  defp insert_reserved_intent(attrs) do
    case %Intent{} |> Intent.reservation_changeset(attrs) |> Repo.insert() do
      {:ok, intent} ->
        Enum.each(intent.episode_ids, &insert_episode_reservation(intent.id, &1))
        intent

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_episode_reservation(intent_id, episode_id) do
    case %IntentEpisode{}
         |> IntentEpisode.changeset(%{intent_id: intent_id, episode_id: episode_id})
         |> Repo.insert() do
      {:ok, _reservation} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp normalize_reservation({:ok, intent}), do: {:ok, intent}

  defp normalize_reservation({:error, %Ecto.Changeset{} = changeset}) do
    cond do
      Keyword.has_key?(changeset.errors, :mapping_snapshot) ->
        {:error, :invalid_mapping_snapshot}

      Keyword.has_key?(changeset.errors, :release_policy_snapshot) ->
        {:error, :invalid_release_policy_snapshot}

      changeset.errors == [] ->
        {:error, changeset}

      true ->
        {:error, :download_intent_busy}
    end
  end

  @doc "Durably submits a movie release and attaches the remote ID to the movie."
  def grab_movie(%Movie{} = movie, %Release{} = release) do
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil ->
        with {:ok, marked} <- ensure_policy_marker(release, movie) do
          reserve_and_reconcile(:movie, movie.id, [], marked)
        end

      %Intent{status: :cleanup_pending} ->
        {:error, :download_intent_busy}

      intent ->
        reconcile_matching_intent(intent, release, [])
    end
  end

  @doc "Durably submits a TV release and creates its guarded episode grab."
  def grab_episodes(release, episode_ids, opts \\ [])

  def grab_episodes(%Release{} = release, episode_ids, opts)
      when episode_ids != [] and is_list(opts) do
    with {:ok, series} <- Catalog.get_single_series_for_episode_ids(episode_ids) do
      grab_validated_episodes(release, episode_ids, series, opts)
    end
  end

  defp grab_validated_episodes(release, episode_ids, series, opts) do
    case overlapping_episode_intent(episode_ids) do
      nil -> reserve_episode_intent(release, episode_ids, series, opts)
      %Intent{status: :cleanup_pending} -> {:error, :download_intent_busy}
      intent -> reconcile_matching_intent(intent, release, episode_ids, opts)
    end
  end

  defp reserve_episode_intent(release, episode_ids, series, opts) do
    with {:ok, marked} <- ensure_policy_marker(release, series) do
      kind = if length(episode_ids) == 1, do: :episode, else: :season_pack
      reserve_and_reconcile(kind, hd(episode_ids), episode_ids, marked, opts)
    end
  end

  @doc """
  Durably submits an operator-chosen book release for `target` and creates its grab.

  An `%EbookRelease{}`/`%AudiobookRelease{}` is converted (`Release.from_book/1`) to the
  `%Release{}` the intent journal and every download client already speak: the client only ever
  needs a title, a URL and a protocol, and giving the behaviour a third release struct would fork
  four adapters to carry fields none of them read. The book-specific evidence stays in the books
  tables, not in the downloader.

  No anime policy marker: `ensure_policy_marker/2` resolves an Anime handling profile, and
  `Cinder.LibraryKind` gives book kinds `handlings: [:standard]` only. Passing a book target
  through it would ask the video policy engine a question with no meaning here.

  Two concrete clauses, one per live book media kind — each pattern-matches BOTH the target's
  `media_kind` AND the release struct's own type, so an `%EbookRelease{}` can never reach the
  audiobook path (or an `%AudiobookRelease{}` the e-book path) by accident: the type match is the
  safety rail, not merely the `media_kind` field. The two clauses are copied scaffolding, not
  shared — the *dispatch* shape (check `Intent`, reserve-or-reconcile) is identical, but the
  release struct being converted differs, and a single clause accepting either shape would let a
  release built for one kind reach the other's pipeline by a caller's mistake rather than a
  compile-time refusal.

  The catch-all clause stays below both concrete ones and is unreachable for the two live kinds
  today — it guards against any *future* third `Cinder.LibraryKind.books()` entry landing here
  with no clause of its own, the same "half-works" failure mode this refusal has always fenced,
  generalized from one unwired kind to any not-yet-wired one.
  """
  def grab_book_target(target, release, opts \\ [])

  def grab_book_target(%BookTarget{media_kind: :ebook} = target, %EbookRelease{} = release, opts) do
    case Repo.get_by(Intent, kind: :book_target, target_id: target.id) do
      nil ->
        reserve_and_reconcile(:book_target, target.id, [], Release.from_book(release), opts)

      %Intent{status: :cleanup_pending} ->
        {:error, :download_intent_busy}

      intent ->
        reconcile_matching_intent(intent, Release.from_book(release), [], opts)
    end
  end

  def grab_book_target(
        %BookTarget{media_kind: :audiobook} = target,
        %AudiobookRelease{} = release,
        opts
      ) do
    case Repo.get_by(Intent, kind: :book_target, target_id: target.id) do
      nil ->
        reserve_and_reconcile(:book_target, target.id, [], Release.from_book(release), opts)

      %Intent{status: :cleanup_pending} ->
        {:error, :download_intent_busy}

      intent ->
        reconcile_matching_intent(intent, Release.from_book(release), [], opts)
    end
  end

  def grab_book_target(%BookTarget{}, _release, _opts),
    do: {:error, :unsupported_media_kind}

  defp reconcile_matching_intent(intent, release, episode_ids, opts \\ []) do
    if same_release?(intent, release) and same_episode_assignment?(intent, episode_ids) and
         operator_initiated?(intent) == Keyword.get(opts, :operator_initiated, false) and
         arbitrate_at_import?(intent) == Keyword.get(opts, :arbitrate_at_import, false) and
         replace?(intent) == Keyword.get(opts, :replace, false),
       do: reconcile_intent(intent),
       else: {:error, :download_intent_busy}
  end

  # One link from two sources, from two indexers of one source, or from one native indexer under
  # two credentials versions is a different release to the intent (#1645). A release with no
  # source reads as Prowlarr's, like an intent with none.
  defp same_release?(%Intent{release: stored} = intent, release) do
    source = indexer_source(stored["indexer_source"])

    intent.protocol == release.protocol and stored["title"] == release.title and
      source == indexer_source(release.indexer_source) and
      indexer_id(intent) == release.indexer_id and
      (source != "native" or stored["credentials_version"] == release.credentials_version) and
      decrypt_download_url(stored) == {:ok, release.download_url}
  end

  defp same_episode_assignment?(%Intent{kind: kind}, []) when kind in [:movie, :book_target],
    do: true

  defp same_episode_assignment?(intent, ids), do: Enum.sort(intent.episode_ids) == Enum.sort(ids)

  defp reserve_and_reconcile(kind, target_id, episode_ids, release, opts \\ []) do
    with {:ok, intent} <-
           reserve_intent(%{
             kind: kind,
             target_id: target_id,
             episode_ids: episode_ids,
             protocol: release.protocol,
             release: release,
             mapping_snapshot: release.mapping_snapshot,
             release_policy_snapshot: release.release_policy_snapshot,
             operator_initiated: Keyword.get(opts, :operator_initiated, false),
             arbitrate_at_import: Keyword.get(opts, :arbitrate_at_import, false),
             replace: Keyword.get(opts, :replace, false)
           }) do
      reconcile_intent(intent)
    end
  end

  defp ensure_policy_marker(%Release{} = release, title) do
    summary = Catalog.media_profile_summary(title)

    cond do
      summary.effective == :anime ->
        mark_anime_policy(release, title)

      MediaProfile.auto_anime_fallback?(summary) and
          not is_nil(release.release_policy_snapshot) ->
        mark_anime_policy(release, title)

      true ->
        {:ok, %{release | release_policy_snapshot: nil}}
    end
  end

  defp mark_anime_policy(release, title) do
    with {:ok, policy} <- AnimePreferences.resolve(title, Settings.anime_defaults()) do
      put_anime_policy_marker(release, policy)
    end
  end

  defp put_anime_policy_marker(%Release{release_policy_snapshot: %{}} = release, _policy),
    do: {:ok, release}

  defp put_anime_policy_marker(%Release{release_policy_snapshot: nil} = release, policy) do
    {:ok, %{release | release_policy_snapshot: AnimePreferences.snapshot(policy, release)}}
  end

  defp put_anime_policy_marker(%Release{}, _policy),
    do: {:error, :invalid_release_policy_snapshot}

  defp overlapping_episode_intent(episode_ids) do
    Repo.one(
      from i in Intent,
        join: r in IntentEpisode,
        on: r.intent_id == i.id,
        where: r.episode_id in ^episode_ids,
        limit: 1
    )
  end

  defp do_submit_intent(%Intent{} = intent) do
    if retry_due?(intent), do: submit_due_intent(intent), else: {:error, :intent_backoff}
  end

  defp submit_due_intent(intent) do
    if submission_target_active?(intent) do
      case configured_client(intent.protocol) do
        {:ok, client} -> submit_with_client(intent, client)
        {:error, reason} -> schedule_retry(intent, reason)
      end
    else
      cleanup_ineligible_intent(intent)
    end
  end

  defp submit_with_client(intent, client) do
    case client.find_by_operation_key(intent.operation_key) do
      {:ok, remote_id} -> store_remote_id(intent, remote_id)
      :not_found -> maybe_add_reserved_release(intent, client)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp maybe_add_reserved_release(intent, client) do
    if submission_target_active?(intent),
      do: add_reserved_release(intent, client),
      else: release_ineligible_after_not_found(intent)
  end

  defp release_ineligible_after_not_found(intent) do
    case Repo.get(Intent, intent.id) do
      nil -> :ok
      fresh -> complete_intent(fresh, :absent)
    end

    {:error, ineligible_reason(intent)}
  end

  @doc "Attaches a durable intent's remote ID to its movie/grab owner and removes the intent."
  def reconcile_intent(%Intent{} = intent), do: with_intent_lock(intent, &do_reconcile_intent/1)

  defp do_reconcile_intent(%Intent{status: :cleanup_pending} = intent), do: do_cleanup(intent)

  defp do_reconcile_intent(%Intent{kind: kind} = intent)
       when kind in [:episode, :season_pack] do
    case Catalog.get_single_series_for_episode_ids(intent.episode_ids) do
      {:ok, _series} -> do_reconcile_valid_intent(intent)
      {:error, reason} -> reject_invalid_episode_intent(intent, reason)
    end
  end

  defp do_reconcile_intent(%Intent{} = intent), do: do_reconcile_valid_intent(intent)

  defp do_reconcile_valid_intent(%Intent{remote_id: nil} = intent) do
    with {:ok, submitted} <- do_submit_intent(intent), do: do_reconcile_intent(submitted)
  end

  defp do_reconcile_valid_intent(%Intent{kind: :movie} = intent), do: reconcile_movie(intent)

  defp do_reconcile_valid_intent(%Intent{kind: :book_target} = intent),
    do: reconcile_book_target(intent)

  defp do_reconcile_valid_intent(%Intent{} = intent), do: reconcile_episodes(intent)

  defp reject_invalid_episode_intent(%Intent{remote_id: nil} = intent, reason) do
    delete_intent(intent)
    {:error, reason}
  end

  defp reject_invalid_episode_intent(%Intent{} = intent, reason),
    do: cleanup_failed_ownership(intent, reason)

  defp with_intent_lock(intent, fun) do
    :global.trans({{__MODULE__, intent.id}, self()}, fn ->
      case Repo.get(Intent, intent.id) do
        nil -> {:error, :intent_completed}
        fresh -> fun.(fresh)
      end
    end)
  end

  @doc false
  def reconcile_pending_intents(kinds) when is_list(kinds) do
    intents =
      Repo.all(
        from i in Intent,
          where: i.kind in ^kinds,
          order_by: [asc: i.id]
      )

    # Each result is dropped. On a permanent submission error, `abandon_reserved/2` has already
    # tried to hold a book target or block a TV release, where its comments say. A movie is not
    # parked here, on purpose (#1491). A `:requested` or `:searching` movie goes back to its
    # poller's search pass as a movie with no intent would: a release a later search grabs gets a
    # freshly encrypted link, and a grab the client refuses for good goes to
    # `MovieLifecycle.record_failure/2` while the movie is still searching, which parks it. A movie
    # in another status keeps its status. When the search pass reaches a movie's stored intent
    # itself, such as when this pass stopped short on a raise or the intent's retry came due after
    # it ran, `start/1` does not return an `:invalid_intent_release` for it either: the intent is
    # dropped and the call goes on as for a movie with no intent (#1564).
    # Each intent whose reconcile returns stamps the tick's progress, so a run of slow grabs in
    # this one poller unit does not read as a stuck poller on `/healthz` (#1656). One grab slower
    # than the stuck limit still does, and a raise ends the unit before its stamp.
    Enum.each(intents, fn intent ->
      reconcile_intent(intent)
      PollerProgress.beat()
    end)

    :ok
  end

  @doc false
  def movie_retry_accounted?(movie_id) do
    Repo.exists?(
      from i in Intent,
        where:
          i.kind == :movie and i.target_id == ^movie_id and i.status == :reserved and
            i.attempt_count > 0
    )
  end

  @doc """
  True while a download intent for `movie_id` can still attach a download to that movie: reserved,
  or submitted and not yet reconciled. A `:cleanup_pending` intent only removes its remote job.
  """
  def movie_intent_pending?(movie_id) do
    Repo.exists?(
      from i in Intent,
        where:
          i.kind == :movie and i.target_id == ^movie_id and i.status in [:reserved, :submitted]
    )
  end

  @doc false
  def pending_episode_ids do
    Repo.all(from r in IntentEpisode, select: r.episode_id) |> MapSet.new()
  end

  # `opts[:expect_remote_id]` (issue #415) is a generation guard for the post-commit fence path
  # only: every EXISTING caller (`MovieLifecycle.cancel/2`, `MovieLifecycle.abort_upgrade/2`,
  # `Catalog.TitleDeletion.delete_movie/3`, the TV grab verification holds) fences BEFORE the
  # target becomes grabbable again, inside the same transaction as the write that makes it so —
  # nothing can race a new reservation in, so "the" intent for this `target_id` is unambiguously
  # the one being torn down. The post-commit sites (the movie/TV
  # `SourceRemoval.remove_after_import/4` fences) invert that ordering on purpose (removing files
  # mid-import is worse — see `SourceRemoval.remove_after_import/4`'s doc), which opens a real
  # window: a concurrent `UpgradeHunter` tick or a "Find a better match" click can reserve a NEW
  # release for this same target between the commit and the fence. Fencing "whatever intent
  # exists" there would silently hijack that NEW intent — flipping it to `:cleanup_pending` and
  # discarding its own `remote_id` in favor of the OLD download's. `expect_remote_id`, passed only
  # by those post-commit callers, refuses to touch an existing intent whose `remote_id` doesn't
  # already match the download being fenced — returning `:mismatch` instead so the caller can fall
  # back to a one-shot, undurable removal (today's pre-#415 behavior) rather than corrupt state.
  # Omitted (the default, every in-transaction caller), this check never runs.
  @doc false
  def fence_movie_cleanup(%Movie{} = movie, opts \\ []) do
    intent = Repo.get_by(Intent, kind: :movie, target_id: movie.id)
    remote_id = if Keyword.get(opts, :include_remote, true), do: movie.download_id
    expect_remote_id = Keyword.get(opts, :expect_remote_id)

    cond do
      conflicting_intent?(intent, expect_remote_id) -> :mismatch
      match?(%Intent{}, intent) -> [mark_cleanup!(intent, remote_id).id]
      is_binary(remote_id) -> [insert_movie_cleanup!(movie, remote_id).id]
      true -> []
    end
  end

  defp conflicting_intent?(_intent, nil), do: false
  defp conflicting_intent?(nil, _expect_remote_id), do: false

  defp conflicting_intent?(%Intent{remote_id: remote_id}, expect_remote_id),
    do: remote_id != expect_remote_id

  # `opts[:expect_remote_id]` — same generation guard as `fence_movie_cleanup/2`'s, same reasoning
  # (only `SourceRemoval`'s post-commit TV sites pass it; every existing in-transaction caller
  # doesn't and sees zero behavior change). Without it, an unrelated intent already holding one of
  # `episode_ids` in `download_intent_episodes` (a concurrent upgrade-hunt/manual grab reserving
  # the SAME episode between this tick's commit and this fence) would both get silently flipped to
  # `:cleanup_pending` by the `pending_ids` mark below AND cause the `carrier_ids` insert to crash
  # on `download_intent_episodes`' `unique_index(:episode_id)` (two intents can never claim one
  # episode). Any conflicting pending intent aborts the WHOLE fence with `:mismatch` — episode_ids
  # here all belong to the ONE grab/download being fenced, so a partial fence (some episodes
  # carried, others not) would split one download's cleanup across two records for no reason.
  @doc false
  def fence_episode_cleanup(episode_ids, grab_specs, opts \\ []) do
    expect_remote_id = Keyword.get(opts, :expect_remote_id)

    pending =
      Repo.all(
        from i in Intent,
          join: r in IntentEpisode,
          on: r.intent_id == i.id,
          where: r.episode_id in ^episode_ids,
          distinct: true
      )

    if expect_remote_id && Enum.any?(pending, &(&1.remote_id != expect_remote_id)) do
      :mismatch
    else
      pending_ids = Enum.map(pending, &mark_cleanup!(&1, nil).id)

      carrier_ids =
        for spec <- grab_specs,
            not Enum.any?(pending, &(&1.remote_id == spec.remote_id)),
            do: insert_episode_cleanup!(spec).id

      Enum.uniq(pending_ids ++ carrier_ids)
    end
  end

  # Unlike `fence_movie_cleanup/2` and `fence_episode_cleanup/2` — which only fence, leaving the
  # delete to a caller that already has its own open transaction (`Catalog`, `Catalog.Grabs`) — this
  # one also deletes the grab. `Cinder.Download.BookPoller` (where the one caller,
  # `BookPoller.fail_download/2`, lives) is a poller under `lib/cinder/download/`: it holds no
  # `Repo` mutations of its own (AGENTS.md), so there is no caller-owned transaction to fence inside
  # of. This opens its own, mirroring `Cinder.Catalog.Grabs.cancel_grab/2`'s fence-then-delete shape
  # but with both writes made here instead of split across two contexts.
  #
  # #398: a failed `client.remove/2` at the end of `BookPoller.fail_download/2` used to discard
  # its result with nothing durable behind it — the grab row carrying `download_id`,
  # `download_protocol`, and `content_path` was already gone by then, so a transient removal
  # failure (client restarting, an API timeout) leaked the remote job and its files forever. The
  # grab and the fenced intent are now deleted/inserted in the same transaction, so a crash
  # between them is impossible; the caller runs `cleanup_intents/1` right after commit for the
  # immediate best-effort attempt, and any failure there leaves the `:cleanup_pending` row for
  # `reconcile_pending_intents/1`'s bounded retry (every `BookPoller` tick) to keep trying.
  #
  # #445: `Books.Grabs.delete_only/1` (not `Books.Grabs.delete/1`) — `Books.Grabs.delete/1`'s own
  # bundled broadcast fired from INSIDE this transaction, before it commits, violating "one
  # transition, one broadcast, emitted after commit." A rolled-back fence (or, under WAL, a
  # `/books/:id` reload racing the still-open write) would have announced a deletion that never
  # happened, or hadn't happened yet. `Books.broadcast/1` now runs after `Repo.transaction/1`
  # returns `{:ok, _}`.
  # #536: unlike `fence_movie_cleanup/2`/`fence_episode_cleanup/3`, every caller of this function
  # runs post-commit with no caller-owned transaction to fence inside of (see above) — there is
  # no safe "before" caller the way movie/episode have, so the `expect_remote_id` generation
  # guard applies unconditionally here rather than being opt-in. A concurrent grab (a stale
  # search result, a manual re-grab) can reserve a NEW intent for this same `book_target_id`
  # between whatever committed earlier and this fence running; `grab.download_id` is
  # unambiguously the download THIS fence is for, so any existing intent whose `remote_id`
  # doesn't already match it is a conflict — refused as `:mismatch` (reusing
  # `conflicting_intent?/2`) rather than silently hijacked (flipped to `:cleanup_pending`,
  # discarding the race winner's own `remote_id`). Every caller falls back to
  # `SourceRemoval.fallback_remove/3`'s one-shot, undurable removal on `:mismatch`, the same
  # degrade the movie/episode fences use.
  @doc false
  def fence_book_cleanup(%BookGrab{} = grab) do
    result =
      Repo.transaction(fn ->
        case Repo.get_by(Intent, kind: :book_target, target_id: grab.book_target_id) do
          %Intent{} = existing -> fence_existing_book_intent(existing, grab)
          nil -> fence_new_book_intent(grab)
        end
      end)

    case result do
      {:ok, intent_ids} ->
        Books.broadcast({:book_grab_deleted, grab.book_target_id})
        {:ok, intent_ids}

      {:error, :mismatch} ->
        :mismatch
    end
  end

  defp fence_existing_book_intent(existing, grab) do
    if conflicting_intent?(existing, grab.download_id) do
      Repo.rollback(:mismatch)
    else
      intent = mark_cleanup!(existing, grab.download_id)
      Books.Grabs.delete_only(grab)
      [intent.id]
    end
  end

  defp fence_new_book_intent(grab) do
    intent = insert_book_cleanup!(grab)
    Books.Grabs.delete_only(grab)
    [intent.id]
  end

  @doc false
  def cleanup_intents(intent_ids) do
    Enum.each(intent_ids, fn id ->
      case Repo.get(Intent, id) do
        nil -> :ok
        intent -> reconcile_intent(intent)
      end
    end)

    :ok
  end

  defp mark_cleanup!(intent, remote_id) do
    attrs = %{
      status: :cleanup_pending,
      attempt_count: 0,
      next_attempt_at: nil,
      last_error: nil
    }

    attrs = if is_binary(remote_id), do: Map.put(attrs, :remote_id, remote_id), else: attrs
    intent |> Intent.changeset(attrs) |> Repo.update!()
  end

  defp insert_movie_cleanup!(movie, remote_id) do
    insert_cleanup_intent!(%{
      operation_key: Ecto.UUID.generate(),
      kind: :movie,
      target_id: movie.id,
      episode_ids: [],
      protocol: movie.download_protocol || :torrent,
      release: %{"title" => movie.release_title || movie.title},
      status: :cleanup_pending,
      remote_id: remote_id
    })
  end

  defp insert_episode_cleanup!(spec) do
    insert_cleanup_intent!(%{
      operation_key: Ecto.UUID.generate(),
      kind: if(length(spec.episode_ids) == 1, do: :episode, else: :season_pack),
      target_id: hd(spec.episode_ids),
      episode_ids: spec.episode_ids,
      protocol: spec.protocol || :torrent,
      release: %{"title" => spec.title || ""},
      status: :cleanup_pending,
      remote_id: spec.remote_id
    })
  end

  defp insert_book_cleanup!(grab) do
    insert_cleanup_intent!(%{
      operation_key: Ecto.UUID.generate(),
      kind: :book_target,
      target_id: grab.book_target_id,
      episode_ids: [],
      protocol: grab.download_protocol,
      release: %{"title" => grab.release_title || ""},
      status: :cleanup_pending,
      remote_id: grab.download_id
    })
  end

  defp insert_cleanup_intent!(attrs) do
    intent = %Intent{} |> Intent.changeset(attrs) |> Repo.insert!()
    Enum.each(intent.episode_ids, &insert_episode_reservation!(intent.id, &1))
    intent
  end

  defp insert_episode_reservation!(intent_id, episode_id) do
    %IntentEpisode{}
    |> IntentEpisode.changeset(%{intent_id: intent_id, episode_id: episode_id})
    |> Repo.insert!()
  end

  defp do_cleanup(intent) do
    if retry_due?(intent), do: cleanup_due_intent(intent), else: {:error, :intent_backoff}
  end

  defp cleanup_due_intent(intent) do
    case configured_client(intent.protocol) do
      {:ok, client} -> cleanup_with_client(intent, client)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp cleanup_with_client(%Intent{remote_id: id} = intent, client) when is_binary(id),
    do: remove_for_cleanup(intent, client, id)

  defp cleanup_with_client(intent, client), do: find_for_cleanup(intent, client)

  defp find_for_cleanup(intent, client) do
    case client.find_by_operation_key(intent.operation_key) do
      :not_found -> complete_intent(intent, :absent)
      {:ok, remote_id} -> persist_then_remove(intent, client, remote_id)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp persist_then_remove(intent, client, remote_id) do
    case store_cleanup_remote_id(intent, remote_id) do
      {:ok, updated} -> remove_for_cleanup(updated, client, remote_id)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp remove_for_cleanup(intent, client, remote_id) do
    case strict_remove(client, remote_id) do
      :ok -> complete_intent(intent, :removed)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp strict_remove(client, remote_id) do
    client.remove(remote_id, delete_files: true)
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp add_reserved_release(intent, client) do
    case decrypt_download_url(intent.release) do
      {:ok, download_url} -> add_decrypted_release(intent, client, download_url)
      {:error, reason} -> abandon_reserved(intent, reason)
    end
  end

  # The client fetches the link only through `fetch:`, which reaches the source the intent recorded
  # (#1650). An intent whose source maps to no module makes no fetch and no add: its reason goes to
  # `schedule_retry/2`, as a client error `GrabFailure.drops?/1` keeps does. A native intent whose
  # indexer changed since the search makes no fetch either, and is dropped (`GrabFailure.check/1`,
  # #1656). This runs only once the client's lookup answered `:not_found`, so a job the client
  # already holds is adopted first.
  defp add_decrypted_release(intent, client, download_url) do
    release = %Release{
      title: intent.release["title"],
      download_url: download_url,
      download_url_origin: intent.release["download_url_origin"],
      protocol: intent.protocol
    }

    with {:ok, module, provenance} <- fetch_source(intent),
         :ok <- GrabFailure.check(provenance),
         fetch = GrabFailure.guard_fetch(fetch_function(module, provenance), module),
         {:ok, remote_id} <-
           client.add(release, operation_key: intent.operation_key, fetch: fetch) do
      store_remote_id(intent, remote_id)
    else
      {:error, reason} ->
        if GrabFailure.drops?(reason),
          do: abandon_reserved(intent, reason),
          else: retry_submission(intent, reason, GrabFailure.retry_class(reason))
    end
  end

  # The retry kinds of a kept failure (`GrabFailure.retry_class/1`, #1658). Only a reserved
  # intent's submission gets here, never a cleanup's, so the cap never drops a remote job's
  # removal. A limit writes only to the reserved row it read.
  defp retry_submission(intent, {:indexer_limit, until} = reason, :limit) do
    own = DateTime.add(DateTime.utc_now(:second), retry_delay(intent), :second)

    claim_retry_generation(intent, %{
      next_attempt_at: Enum.max([until, own], DateTime),
      last_error: GrabFailure.retry_error(reason)
    })

    {:error, reason}
  end

  defp retry_submission(intent, reason, :capped) do
    if (intent.attempt_count || 0) + 1 >= GrabFailure.retry_cap(),
      do: exhaust_retries(intent, reason),
      else: schedule_retry(intent, reason)
  end

  defp retry_submission(intent, reason, :uncapped), do: schedule_retry(intent, reason)

  # The attempt that reaches the cap drops the grab with no block row. A movie's drop claims the
  # attempt count it read, as a retry does, and its strike, for a movie still in the search pass,
  # shares that transaction; a stale claim drops and counts nothing. A TV intent's episodes and a
  # movie search again; a book target, with no search pass, is held. Every kind's drop claims the
  # row first, so an intent a cancel turned into a cleanup during the add stays as it is.
  defp exhaust_retries(%Intent{kind: :movie} = intent, reason) do
    Logger.warning("movie #{intent.target_id} grab hit its retry cap after #{inspect(reason)}")

    MovieLifecycle.record_submission_failure(intent.target_id, :grab_retries_exhausted, fn ->
      claim_retry_generation(intent, :delete)
    end)

    {:error, :grab_retries_exhausted}
  end

  defp exhaust_retries(intent, reason) do
    Logger.warning("intent #{intent.id} grab hit its retry cap after #{inspect(reason)}")

    if claim_retry_generation(intent, :delete) == :ok,
      do: abandon_reserved(intent, :grab_retries_exhausted),
      else: {:error, reason}
  end

  @doc """
  The indexer source that fetches `intent`'s download link, read from the source the intent
  recorded and never from the configured one: `{:ok, module, provenance}`, where `provenance` is
  `[indexer_source: source, indexer_id:, credentials_version:]`, the last two `nil` when the
  intent records none. `"prowlarr"` maps to `IndexerSource.Prowlarr` and `"native"` to
  `IndexerSource.Native`. An intent with no recorded source, such as one reserved before #1645,
  is Prowlarr's. Any other source answers `{:error, :unknown_indexer_source}`.
  """
  @spec fetch_source(Intent.t()) :: {:ok, module(), keyword()} | {:error, :unknown_indexer_source}
  def fetch_source(%Intent{release: stored} = intent) do
    source = indexer_source(stored["indexer_source"])

    case Map.fetch(@fetch_sources, source) do
      {:ok, module} ->
        {:ok, module,
         [
           indexer_source: source,
           indexer_id: indexer_id(intent),
           credentials_version: stored["credentials_version"]
         ]}

      :error ->
        {:error, :unknown_indexer_source}
    end
  end

  @doc """
  The `fetch:` function a download client calls with its link, origin and fetch options: it calls
  `module.fetch_download/3` with those options plus `provenance`, whose keys replace any key of
  the same name.
  """
  @spec fetch_function(module(), keyword()) ::
          (String.t(), String.t() | nil, keyword() ->
             {:ok, binary()} | {:magnet, String.t()} | {:error, term()})
  def fetch_function(module, provenance) do
    fn url, source_origin, opts ->
      module.fetch_download(url, source_origin, Keyword.merge(opts, provenance))
    end
  end

  defp decrypt_download_url(%{"download_url_ciphertext" => encoded}) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, url} when is_binary(url) <- Vault.decrypt(ciphertext) do
      {:ok, url}
    else
      _ -> {:error, :invalid_intent_release}
    end
  end

  defp decrypt_download_url(_release), do: {:error, :invalid_intent_release}

  defp store_remote_id(intent, remote_id) do
    case Repo.get(Intent, intent.id) do
      %Intent{status: :cleanup_pending} = cleanup ->
        cleanup
        |> Intent.changeset(%{
          remote_id: remote_id,
          attempt_count: 0,
          next_attempt_at: nil,
          last_error: nil
        })
        |> Repo.update()

      %Intent{} = fresh ->
        fresh
        |> Intent.changeset(%{
          status: :submitted,
          remote_id: remote_id,
          attempt_count: 0,
          next_attempt_at: nil,
          last_error: nil
        })
        |> Repo.update()

      nil ->
        {:error, :intent_completed}
    end
  end

  defp store_cleanup_remote_id(intent, remote_id) do
    intent |> Intent.changeset(%{remote_id: remote_id}) |> Repo.update()
  end

  defp retry_delay(intent), do: GrabFailure.retry_delay((intent.attempt_count || 0) + 1)

  defp schedule_retry(intent, reason) do
    retry_attrs = %{
      attempt_count: (intent.attempt_count || 0) + 1,
      next_attempt_at: DateTime.utc_now(:second) |> DateTime.add(retry_delay(intent), :second),
      last_error: GrabFailure.retry_error(reason)
    }

    case intent do
      %Intent{kind: :movie, status: :reserved} ->
        MovieLifecycle.record_submission_failure(intent.target_id, reason, fn ->
          claim_retry_generation(intent, retry_attrs)
        end)

      %Intent{} ->
        intent |> Intent.changeset(retry_attrs) |> Repo.update()
    end

    {:error, reason}
  end

  # Counts this failure once: the reserved intent's attempt count must still be the one this
  # process read, so a concurrent reconcile that already counted it leaves `:stale`. `:delete`
  # drops the intent instead of writing `retry_attrs` (`exhaust_retries/2`).
  defp claim_retry_generation(intent, retry_attrs) do
    observed_attempt = intent.attempt_count || 0

    query =
      from(i in Intent,
        where:
          i.id == ^intent.id and i.status == :reserved and i.attempt_count == ^observed_attempt
      )

    claimed =
      if retry_attrs == :delete,
        do: Repo.delete_all(query),
        else:
          Repo.update_all(query,
            set: Map.to_list(retry_attrs) ++ [updated_at: DateTime.utc_now(:second)]
          )

    if match?({1, _}, claimed), do: :ok, else: :stale
  end

  defp retry_due?(%Intent{next_attempt_at: nil}), do: true

  defp retry_due?(%Intent{next_attempt_at: next}),
    do: DateTime.compare(next, DateTime.utc_now()) in [:lt, :eq]

  # A permanently rejected submission (a torrent the client cannot parse, a URL it refuses, a
  # release whose stored ciphertext no longer decrypts) drops the reservation and reports the
  # reason to the caller. A grab from the movie poller's search pass then parks the movie when it
  # is still in the search pass (`MovieLifecycle.record_failure/2`), and one from the TV poller's
  # spends a search attempt, after Cinder tries to block the release for the series on each
  # reason but `:invalid_intent_release` (below). `start/1` does not return the
  # `:invalid_intent_release` of a movie intent an earlier grab stored: it goes on as for a movie
  # with no intent (#1564).
  #
  # The two indexer failures `GrabFailure.drops?/1` adds, `:indexer_changed` and
  # `:indexer_auth_failed`, drop the reservation here too (#1656). Neither blocks a TV release nor
  # a held book target's release title. The movie search pass takes no strike for an
  # `:indexer_changed` its grab call returns, and the TV sweep spends no search attempt on it in
  # that sweep.
  # An `:indexer_auth_failed` that a grab call returns counts there as any failed grab does: one
  # strike, never a park on first sight. `start/1` goes on as for a movie with no intent after a
  # stored intent's `:indexer_changed`, as after its `:invalid_intent_release`.
  #
  # For a book that report is not enough, and the difference is the missing search sweep.
  # `reconcile_pending_intents/1` discards the report, and a movie or episode it leaves in its
  # pre-grab state is re-derived by its poller's next search pass; a book
  # target has no such pass, so a deleted intent with no grab leaves a `:monitored` row that is
  # byte-identical to "nobody picked a release yet" — and `reconcile_pending_intents/1`, which the
  # book poller runs every tick, discards this return value, so the failure would be invisible as
  # well as permanent. Hold it with the reason instead.
  defp abandon_reserved(
         %Intent{kind: :book_target, target_id: target_id, release: release} = intent,
         reason
       ) do
    Logger.warning("book target #{target_id} submission rejected: #{inspect(reason)}")
    title = if GrabFailure.blocks_book_release?(reason), do: release["title"]
    hold_book_target(target_id, reason, title, replace?(intent))
    delete_intent(intent)
    {:error, reason}
  end

  # A TV release the search pass picked is blocked for its series first, on each of these reasons
  # but `:invalid_intent_release`, which says a stored link could not be read back, not that the
  # release is bad (#1492). This is the one place both a fresh grab and a stored intent's retry
  # pass through. An operator-initiated intent (a release picked by hand, or the upgrade sweep's)
  # is not blocked. The block row it tries to write carries the indexer id the intent stored and
  # its source, `"prowlarr"` for an intent that stored an id and no source, so it does not match
  # the same title from another indexer (another row, such as a `stalled` one, still can). For an
  # intent stored with no id, such as one reserved before #1515, the row carries neither and
  # matches the title from every indexer.
  defp abandon_reserved(%Intent{kind: kind} = intent, reason)
       when kind in [:episode, :season_pack] do
    if GrabFailure.refused_release?(reason) and not operator_initiated?(intent) do
      series_id = fn -> intent_series_id(intent) end
      Catalog.block_series_release(series_id, release_title(intent), reason, block_scope(intent))
    end

    delete_intent(intent)
    {:error, reason}
  end

  defp abandon_reserved(intent, reason) do
    delete_intent(intent)
    {:error, reason}
  end

  # Raises when the episodes no longer share one series: `Catalog.block_series_release/4` logs that
  # and records nothing.
  defp intent_series_id(intent) do
    {:ok, series} = Catalog.get_single_series_for_episode_ids(intent.episode_ids)
    series.id
  end

  defp release_title(%Intent{release: %{"title" => title}}) when is_binary(title), do: title
  defp release_title(_intent), do: nil

  defp indexer_id(%Intent{release: %{"indexer_id" => id}}) when is_integer(id), do: id
  defp indexer_id(_intent), do: nil

  # An intent stored with no indexer source, such as every one reserved before #1645, is
  # Prowlarr's, the one source there was.
  defp indexer_source(nil), do: "prowlarr"
  defp indexer_source(source), do: source

  defp block_scope(%Intent{release: stored} = intent) do
    if id = indexer_id(intent), do: {indexer_source(stored["indexer_source"]), id}
  end

  defp hold_book_target(target_id, reason, release_title, replace?) do
    case Repo.get(BookTarget, target_id) do
      %BookTarget{} = target ->
        Books.hold_target(target, reason, release_title, false, replace: replace?)

      # Deleted mid-flight: nothing to park, and nothing left to be silent about.
      nil ->
        :ok
    end
  end

  defp cleanup_ineligible_intent(intent) do
    case Repo.get(Intent, intent.id) do
      nil ->
        {:error, :intent_completed}

      fresh ->
        fresh = if fresh.status == :cleanup_pending, do: fresh, else: mark_cleanup!(fresh, nil)
        do_cleanup(fresh)
        {:error, ineligible_reason(intent)}
    end
  end

  defp ineligible_reason(%Intent{kind: :movie, target_id: movie_id}) do
    if Repo.get(Movie, movie_id), do: :stale_target, else: :stale_entry
  end

  # `:download_intent_busy` when the target would offer the intent's action with no grab in
  # progress (`:monitored` for a fresh grab, or `:available` for a replace-flagged one): the only
  # way it is ineligible is that it already holds a grab, and "busy" is what a caller can act on.
  # A target that would not offer it genuinely moved (unmonitored, held, or the wrong one of
  # `:monitored`/`:available` for the flag), and a missing row is a stale entry.
  defp ineligible_reason(%Intent{kind: :book_target, target_id: target_id} = intent) do
    case Repo.get(BookTarget, target_id) do
      nil ->
        :stale_entry

      target ->
        if Books.Attention.offers?(target, false, book_action(intent)),
          do: :download_intent_busy,
          else: :stale_target
    end
  end

  defp ineligible_reason(%Intent{}), do: :stale_target

  defp book_action(intent), do: if(replace?(intent), do: :replace, else: :manual_search)

  # A verification hold still owns its download, so no new submission may attach over it: a manual
  # grab rendered while the movie was plainly parked must not reach the client once it is held.
  defp submission_target_active?(%Intent{kind: :movie, target_id: movie_id}) do
    case Repo.get(Movie, movie_id) do
      %Movie{status: status, verification_hold_origin: nil} ->
        status in [:requested, :searching, :no_match, :search_failed, :import_failed, :available]

      _held_or_missing ->
        false
    end
  end

  # A book target is submittable while it offers the intent's action (`Books.Attention`):
  # `:manual_search` (`:monitored`, no grab) or, for a replace-flagged intent, `:replace`
  # (`:available`, no grab). A "Find a better match" grab never moves its target out of
  # `:available` for its whole download/import cycle (grabs never touch `book_targets.status`),
  # so gating on `:monitored` alone made a replace submission unreachable in production —
  # `create_book_grab/1` was never called. A non-replace intent still refuses on `:available`: a
  # fresh grab is only ever created for a `:monitored` target, so seeing one already `:available`
  # mid-flight is someone else's more recent decision.
  defp submission_target_active?(%Intent{kind: :book_target, target_id: target_id} = intent) do
    case Repo.get(BookTarget, target_id) do
      %BookTarget{} = target ->
        grab_in_progress? = not is_nil(Books.Grabs.for_target(target_id))
        Books.Attention.offers?(target, grab_in_progress?, book_action(intent))

      nil ->
        false
    end
  end

  defp submission_target_active?(%Intent{episode_ids: episode_ids} = intent) do
    allow_available? = operator_initiated?(intent)

    Repo.exists?(
      from e in Cinder.Catalog.Episode,
        where:
          e.id in ^episode_ids and is_nil(e.grab_id) and
            ((e.monitored == true and is_nil(e.file_path)) or
               (^allow_available? and not is_nil(e.file_path)))
    )
  end

  defp operator_initiated?(%Intent{release: release}),
    do: is_map(release) and release["operator_initiated"] == true

  defp arbitrate_at_import?(%Intent{release: release}),
    do: is_map(release) and release["arbitrate_at_import"] == true

  defp replace?(%Intent{release: release}),
    do: is_map(release) and release["replace"] == true

  # A book target's owner row is its grab, created here on first reconcile. The grab's unique
  # `book_target_id` index is the double-grab fence: a second tick racing this one loses the
  # insert and adopts the winner's row rather than submitting a second download.
  defp reconcile_book_target(%Intent{remote_id: remote_id, target_id: target_id} = intent) do
    case Books.Grabs.by_download(remote_id, intent.protocol) do
      %BookGrab{book_target_id: ^target_id} = grab ->
        complete_intent(intent, grab)

      %BookGrab{} ->
        # The remote job belongs to a DIFFERENT target's grab. Never adopt it — two targets would
        # then import from one payload and the loser would report a file it does not own.
        #
        # Delete this intent WITHOUT touching the client: `cleanup_failed_ownership/2` would run
        # `client.remove(remote_id, delete_files: true)` on a download the other target owns and
        # is still using, destroying its bytes. This intent never created that job (it found it
        # already claimed), so it has nothing of its own to clean up.
        delete_intent(intent)
        {:error, :download_intent_busy}

      nil ->
        # Revalidate before taking ownership. The eligibility check at submission time is not
        # enough: an intent can persist its remote id, crash before reconciling, and be picked up
        # after an operator unmonitored or held the target — creating a grab for a target nobody
        # is waiting on. `submission_target_active?/1` re-reads it now.
        if submission_target_active?(intent),
          do: create_book_grab(intent),
          else: cleanup_ineligible_intent(intent)
    end
  end

  defp create_book_grab(%Intent{remote_id: remote_id, target_id: target_id} = intent) do
    opts = [replace: replace?(intent), release_size: Intent.release_size(intent)]

    case Books.Grabs.create(target_id, remote_id, intent.protocol, intent.release["title"], opts) do
      {:ok, grab} ->
        complete_intent(intent, grab)

      # Lost the insert race, or an operator grabbed a different release for this target between
      # this intent's reservation and now. Either way the target already has its one in-flight
      # download, and that download's remote job is the SAME id this intent holds (the race is on
      # the grab row, not the client), so removing it would destroy the winner's download. Drop
      # the intent and let the winning grab own the job.
      {:error, :book_grab_exists} ->
        delete_intent(intent)
        {:error, :download_intent_busy}

      {:error, _changeset} ->
        cleanup_failed_ownership(intent, :stale_target)
    end
  end

  defp reconcile_movie(%Intent{remote_id: remote_id, target_id: movie_id} = intent) do
    case Repo.get(Movie, movie_id) do
      %Movie{download_id: ^remote_id} = movie ->
        complete_intent(intent, movie)

      %Movie{} = movie ->
        attach_movie(intent, movie)

      nil ->
        cleanup_failed_ownership(intent, :stale_entry)
    end
  end

  defp attach_movie(intent, movie) do
    download = %{
      download_id: intent.remote_id,
      download_protocol: intent.protocol,
      release_title: intent.release["title"],
      release_size: Intent.release_size(intent),
      release_policy_snapshot: intent.release_policy_snapshot
    }

    case MovieLifecycle.attach(movie, download) do
      {:ok, updated} -> complete_intent(intent, updated)
      {:error, _} -> cleanup_failed_ownership(intent, :stale_target)
    end
  end

  defp reconcile_episodes(%Intent{remote_id: remote_id} = intent) do
    case Repo.get_by(Grab, download_id: remote_id, download_protocol: intent.protocol) do
      %Grab{} = grab ->
        complete_intent(intent, grab)

      nil ->
        # Only an operator's grab (a manual pick, the upgrade sweep) gives its episodes a fresh
        # search budget. A sweep grab keeps the count, so a release that parks on every grab runs
        # the budget out instead of being grabbed again forever (#1586).
        result =
          if is_nil(intent.mapping_snapshot) and is_nil(intent.release_policy_snapshot) do
            Catalog.create_grab(
              remote_id,
              intent.protocol,
              intent.episode_ids,
              intent.release["title"],
              reset_attempts: operator_initiated?(intent),
              allow_available: operator_initiated?(intent),
              arbitrate_at_import: arbitrate_at_import?(intent),
              release_size: Intent.release_size(intent)
            )
          else
            Catalog.create_grab_from_intent(intent)
          end

        case result do
          {:ok, grab} -> complete_intent(intent, grab)
          {:error, _} -> cleanup_failed_ownership(intent, :no_episodes_linked)
        end
    end
  rescue
    error -> cleanup_failed_ownership(intent, error)
  catch
    kind, value -> cleanup_failed_ownership(intent, {kind, value})
  end

  defp cleanup_failed_ownership(intent, reason) do
    case intent
         |> Intent.changeset(%{status: :cleanup_pending, next_attempt_at: nil})
         |> Repo.update() do
      {:ok, cleanup} ->
        do_cleanup(cleanup)
        {:error, reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp complete_intent(intent, owner) do
    delete_intent(intent)
    {:ok, owner}
  end

  defp delete_intent(intent) do
    Repo.delete(intent, allow_stale: true)
    :ok
  end

  defp configured_client(protocol) do
    case client_for(protocol) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, :no_client}
    end
  end

  @doc """
  Hands `movie` off to the download client. Returns `{:ok, movie}` with the
  movie's new status (`:downloading` or `:no_match`), or `{:error, reason}`.

  Return values:
  - `{:ok, %Movie{status: :downloading}}` — release found and handed to client.
  - `{:ok, %Movie{status: :no_match}}` — indexer returned results but none survived scoring.
  - `{:error, :tmdb_unavailable}` — transient TMDB error; movie stays `:requested`.
  - `{:error, reason}` — indexer or client error; movie left in `:searching`.

  A movie with a stored download intent hands it to `reconcile_intent/1` instead of searching, and
  returns its result. When that intent's saved download link cannot be read back
  (`:invalid_intent_release`), or its grab is dropped as `:indexer_changed` (#1656: its native
  indexer changed after the search, or its recorded source is no longer the selected one and its
  fetch failed with an error outside `permanent_submission_errors/0`,
  `Cinder.Download.GrabFailure`), the intent is dropped and the call goes on as for a movie with
  no intent, once: either reason from the grab that search makes is returned (#1564).
  """
  def start(%Movie{} = movie) do
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil -> do_start(movie)
      intent -> start_from_intent(movie, intent)
    end
  end

  defp start_from_intent(movie, intent) do
    case reconcile_intent(intent) do
      {:error, reason} when reason in [:invalid_intent_release, :indexer_changed] ->
        do_start(movie)

      result ->
        result
    end
  end

  defp do_start(movie) do
    # Every MovieLifecycle verb below is a compare-and-swap on the struct this unit read, so a
    # user cancel landing during the indexer/client I/O is never overwritten; a
    # {:error, :stale_status} skips the unit — the next tick re-derives.
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- MovieLifecycle.start_search(movie, imdb_id) do
      case search_movie(movie, imdb_id) do
        {:ok, release} ->
          grab_if_space(movie, release)

        :no_match ->
          MovieLifecycle.no_match(movie, :no_match)

        :no_language_match ->
          MovieLifecycle.no_match(movie, :no_language_match)

        {:waiting_for_preferred_group, %{retry_at: retry_at}} ->
          Logger.info("movie #{movie.id} waiting for preferred anime group until #{retry_at}")
          {:ok, movie}

        {:error, _} = err ->
          err
      end
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  The best release currently on offer for `movie` under the household's policy — the *search* half
  of `start/1`, with no status transition and no grab.

  `Cinder.Catalog.UpgradeHunter` needs exactly this: an `:available` movie must stay `:available`
  (its `file_path` points at the live library file) while it asks whether anything better exists.
  Returns what the underlying search returns — `{:ok, %Release{}}`, `:no_match`,
  `:no_language_match`, `{:waiting_for_preferred_group, _}` or `{:error, reason}`.
  """
  def best_release_for(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie), do: search_movie(movie, imdb_id)
  end

  # One indexer source per search (`IndexerSource.configured/0`, read once): the standard search
  # and its anime fallback both run on it.
  defp search_movie(movie, imdb_id) do
    opts =
      movie
      |> HouseholdPolicy.for_target()
      |> Keyword.put(:indexer_source, IndexerSource.configured())

    summary = Catalog.media_profile_summary(movie)
    context = Catalog.movie_acquisition_context(movie)

    case summary.effective do
      :anime -> anime_movie_result(movie, imdb_id, context, opts)
      :standard -> standard_movie_result(movie, imdb_id, context, opts, summary)
    end
  end

  # One decision on the Anime hold per search: the anime fallback makes it when it runs, otherwise
  # a stale marker goes the way the operator's fix would take it (#791). A nil imdb_id (TMDB
  # publishes none for this title) degrades to the guarded free-text search — see issue #195.
  defp standard_movie_result(movie, imdb_id, context, opts, summary) do
    result = Acquisition.best_release(imdb_id, context, opts)

    if result == :no_match and MediaProfile.auto_anime_fallback?(summary) do
      anime_movie_result(movie, imdb_id, context, opts)
    else
      Catalog.reresolve_anime_hold(movie)
      result
    end
  end

  defp anime_movie_result(movie, imdb_id, context, opts) do
    case AnimePreferences.resolve(movie, Settings.anime_defaults()) do
      {:ok, policy} ->
        Catalog.set_anime_hold(movie, nil)

        Acquisition.best_anime_movie(
          imdb_id,
          context,
          opts ++ [anime_policy: policy]
        )

      {:error, reason} ->
        # DB-visible hold (badges + /activity), re-evaluated every sweep: the next tick
        # with satisfiable preferences clears it and searches normally.
        Catalog.set_anime_hold(movie, reason)
        {:error, :invalid_anime_preferences}
    end
  end

  @doc """
  Resolves the download-client module for `protocol` (`:torrent | :usenet`).
  Returns `{:ok, module}` or `:error` when no client is configured for it. A
  `nil` protocol (a row from before download_protocol existed) resolves to
  `:torrent`.
  """
  def client_for(protocol) do
    :cinder
    |> Application.fetch_env!(:download_clients)
    |> Map.fetch(protocol || :torrent)
  end

  @doc "The protocols with a configured download client."
  def available_protocols do
    :cinder |> Application.fetch_env!(:download_clients) |> Map.keys()
  end

  defp ensure_imdb_id(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id) and imdb_id != "" do
    {:ok, imdb_id}
  end

  # `{:ok, nil}` — TMDB genuinely publishes no IMDb id for this title (it happens; issue #195).
  # The search degrades to free-text rather than parking, so the movie is at least looked for.
  defp ensure_imdb_id(%Movie{tmdb_id: tmdb_id}) do
    case Catalog.get_movie(tmdb_id) do
      {:ok, %{imdb_id: imdb_id}} when is_binary(imdb_id) and imdb_id != "" -> {:ok, imdb_id}
      {:ok, _} -> {:ok, nil}
      {:error, _} -> {:error, :tmdb_unavailable}
    end
  end

  @doc """
  Whether a release of `size_bytes` fits on a download root once the bytes in-flight downloads
  still have to write (`Cinder.Download.GrabReserve`) are set aside. The one entry point of the
  automatic grab paths: the movie search, the TV sweep and both upgrade hunts.
  `Cinder.Disk.grab_space_available?/2` says when it fails open.
  """
  @spec grab_space_available?(non_neg_integer() | nil) :: boolean()
  def grab_space_available?(size_bytes),
    do: Cinder.Disk.grab_space_available?(size_bytes, GrabReserve.bytes())

  # Pre-grab disk guard: don't hand a release to the client when no download root can hold it. The
  # poller treats {:insufficient_disk_space, _} as a skip (no attempt burned, no park) — space may
  # free up.
  defp grab_if_space(movie, release) do
    if grab_space_available?(release.size),
      do: add_to_client(movie, release),
      else: {:error, {:insufficient_disk_space, release.size}}
  end

  defp add_to_client(movie, release) do
    grab_movie(movie, release)
  end
end
