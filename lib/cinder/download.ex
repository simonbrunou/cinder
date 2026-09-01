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
  alias Cinder.{Acquisition, Books, Catalog, Library, Notifier, Repo, Settings, Vault}
  alias Cinder.Acquisition.{AnimePreferences, BookRelease, Release}
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog.{Grab, MediaProfile, Movie}
  alias Cinder.Download.{Intent, IntentEpisode}

  @retry_base_seconds 5
  @retry_max_seconds 300
  @permanent_submission_errors [
    :unsupported_download_url,
    :bad_torrent,
    :invalid_intent_release,
    :add_rejected
  ]

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

    release_attrs =
      if Map.get(attrs, :operator_initiated, false),
        do: Map.put(release_attrs, "operator_initiated", true),
        else: release_attrs

    # Same shape as operator_initiated, and deliberately a SECOND flag: both the manual season
    # search and the upgrade sweep set operator_initiated (it is what lets an intent target
    # episodes that already have a file), so it cannot tell attended from unattended (#250).
    release_attrs =
      if Map.get(attrs, :arbitrate_at_import, false),
        do: Map.put(release_attrs, "arbitrate_at_import", true),
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

  A `%BookRelease{}` is converted to the `%Release{}` the intent journal and every download client
  already speak: the client only ever needs a title, a URL and a protocol, and giving the
  behaviour a second release struct would fork four adapters to carry fields none of them read.
  The book-specific evidence stays in the books tables, not in the downloader.

  No anime policy marker: `ensure_policy_marker/2` resolves an Anime handling profile, and
  `Cinder.LibraryKind` gives book kinds `handlings: [:standard]` only. Passing a book target
  through it would ask the video policy engine a question with no meaning here.

  `:ebook` only. `:audiobook` is a live media kind with its own library root, and nothing
  downstream of here is audiobook-aware: `BookSources` accepts `.epub`/`.azw3`/`.mobi`, so an
  audiobook target handed an e-book release would publish an EPUB into the audiobook root and
  report the audiobook available. Audiobooks are B7; until then this refuses rather than
  half-works.
  """
  def grab_book_target(%BookTarget{media_kind: :ebook} = target, %BookRelease{} = release) do
    case Repo.get_by(Intent, kind: :book_target, target_id: target.id) do
      nil ->
        reserve_and_reconcile(:book_target, target.id, [], book_release(release))

      %Intent{status: :cleanup_pending} ->
        {:error, :download_intent_busy}

      intent ->
        reconcile_matching_intent(intent, book_release(release), [])
    end
  end

  def grab_book_target(%BookTarget{}, %BookRelease{}), do: {:error, :unsupported_media_kind}

  # A book release carries no mapping or policy snapshot: both are video-pipeline evidence (an
  # episode-numbering decision and an Anime language policy). Left nil, `Intent`'s validators
  # accept them and the reservation's equality checks pass unchanged.
  defp book_release(%BookRelease{} = release) do
    %Release{
      title: release.title,
      download_url: release.download_url,
      download_url_origin: release.download_url_origin,
      protocol: release.protocol
    }
  end

  defp reconcile_matching_intent(intent, release, episode_ids, opts \\ []) do
    if same_release?(intent, release) and same_episode_assignment?(intent, episode_ids) and
         operator_initiated?(intent) == Keyword.get(opts, :operator_initiated, false) and
         arbitrate_at_import?(intent) == Keyword.get(opts, :arbitrate_at_import, false),
       do: reconcile_intent(intent),
       else: {:error, :download_intent_busy}
  end

  defp same_release?(intent, release) do
    intent.protocol == release.protocol and intent.release["title"] == release.title and
      decrypt_download_url(intent.release) == {:ok, release.download_url}
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
             arbitrate_at_import: Keyword.get(opts, :arbitrate_at_import, false)
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

  @doc "Finds or submits the reserved remote job, then records its normal downloader ID."
  def submit_intent(%Intent{} = intent), do: with_intent_lock(intent, &submit_valid_intent/1)

  defp submit_valid_intent(%Intent{} = intent),
    do: with_valid_episode_intent(intent, &do_submit_intent/1)

  defp do_submit_intent(%Intent{status: :submitted, remote_id: id} = intent)
       when is_binary(id),
       do: {:ok, intent}

  defp do_submit_intent(%Intent{status: :cleanup_pending}),
    do: {:error, :cleanup_pending}

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

  defp do_reconcile_intent(%Intent{} = intent),
    do: with_valid_episode_intent(intent, &do_reconcile_valid_intent/1)

  defp with_valid_episode_intent(%Intent{status: :cleanup_pending} = intent, fun),
    do: fun.(intent)

  defp with_valid_episode_intent(%Intent{kind: kind} = intent, fun)
       when kind in [:episode, :season_pack] do
    case Catalog.get_single_series_for_episode_ids(intent.episode_ids) do
      {:ok, _series} -> fun.(intent)
      {:error, reason} -> reject_invalid_episode_intent(intent, reason)
    end
  end

  defp with_valid_episode_intent(%Intent{} = intent, fun), do: fun.(intent)

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

    Enum.each(intents, &reconcile_intent/1)
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

  @doc false
  def pending_episode_ids do
    Repo.all(from r in IntentEpisode, select: r.episode_id) |> MapSet.new()
  end

  @doc false
  def fence_movie_cleanup(%Movie{} = movie, opts \\ []) do
    intent = Repo.get_by(Intent, kind: :movie, target_id: movie.id)
    remote_id = if Keyword.get(opts, :include_remote, true), do: movie.download_id

    case {intent, remote_id} do
      {%Intent{} = existing, _} -> [mark_cleanup!(existing, remote_id).id]
      {nil, id} when is_binary(id) -> [insert_movie_cleanup!(movie, id).id]
      {nil, _} -> []
    end
  end

  @doc false
  def fence_episode_cleanup(episode_ids, grab_specs) do
    pending =
      Repo.all(
        from i in Intent,
          join: r in IntentEpisode,
          on: r.intent_id == i.id,
          where: r.episode_id in ^episode_ids,
          distinct: true
      )

    pending_ids = Enum.map(pending, &mark_cleanup!(&1, nil).id)

    carrier_ids =
      for spec <- grab_specs,
          not Enum.any?(pending, &(&1.remote_id == spec.remote_id)),
          do: insert_episode_cleanup!(spec).id

    Enum.uniq(pending_ids ++ carrier_ids)
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

  defp add_decrypted_release(intent, client, download_url) do
    release = %Release{
      title: intent.release["title"],
      download_url: download_url,
      download_url_origin: intent.release["download_url_origin"],
      protocol: intent.protocol
    }

    case client.add(release, operation_key: intent.operation_key) do
      {:ok, remote_id} ->
        store_remote_id(intent, remote_id)

      {:error, reason} when reason in @permanent_submission_errors ->
        abandon_reserved(intent, reason)

      {:error, reason} ->
        schedule_retry(intent, reason)
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

  defp schedule_retry(intent, reason) do
    attempt = (intent.attempt_count || 0) + 1
    delay = min(@retry_base_seconds * Integer.pow(2, min(attempt - 1, 6)), @retry_max_seconds)

    retry_attrs = %{
      attempt_count: attempt,
      next_attempt_at: DateTime.utc_now(:second) |> DateTime.add(delay, :second),
      last_error: retry_error(reason)
    }

    case intent do
      %Intent{kind: :movie, status: :reserved} ->
        Catalog.account_movie_intent_retry(intent, retry_attrs, reason)

      %Intent{} ->
        intent |> Intent.changeset(retry_attrs) |> Repo.update()
    end

    {:error, reason}
  end

  defp retry_error(reason) when is_atom(reason), do: inspect(reason)

  defp retry_error({tag, value}) when is_atom(tag) and (is_atom(value) or is_integer(value)),
    do: inspect({tag, value})

  # Downloader errors can contain response bodies, request URLs, or exception
  # structs. Keep only the stable error class for those shapes.
  defp retry_error({tag, _value}) when is_atom(tag), do: inspect(tag)

  defp retry_error(_reason), do: "client_error"

  defp retry_due?(%Intent{next_attempt_at: nil}), do: true

  defp retry_due?(%Intent{next_attempt_at: next}),
    do: DateTime.compare(next, DateTime.utc_now()) in [:lt, :eq]

  # A permanently rejected submission (a torrent the client cannot parse, a URL it refuses, a
  # release whose stored ciphertext no longer decrypts) drops the reservation and reports the
  # reason to the caller.
  #
  # For a book that report is not enough, and the difference is the missing search sweep. A movie
  # or episode left in its pre-grab state is re-derived by its poller's next search pass; a book
  # target has no such pass, so a deleted intent with no grab leaves a `:monitored` row that is
  # byte-identical to "nobody picked a release yet" — and `reconcile_pending_intents/1`, which the
  # book poller runs every tick, discards this return value, so the failure would be invisible as
  # well as permanent. Hold it with the reason instead.
  defp abandon_reserved(%Intent{kind: :book_target, target_id: target_id} = intent, reason) do
    Logger.warning("book target #{target_id} submission rejected: #{inspect(reason)}")
    hold_book_target(target_id, reason)
    delete_intent(intent)
    {:error, reason}
  end

  defp abandon_reserved(intent, reason) do
    delete_intent(intent)
    {:error, reason}
  end

  defp hold_book_target(target_id, reason) do
    case Repo.get(BookTarget, target_id) do
      %BookTarget{} = target -> Books.hold_target(target, reason)
      # Deleted mid-flight: nothing to park, and nothing left to be silent about.
      nil -> :ok
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

  # `:download_intent_busy` when the target is still monitored: the only way a monitored target
  # is ineligible is that it already holds a grab, and "busy" is what a caller can act on — a
  # manual-search panel wants to say "a download is already in flight", not "stale target".
  # A non-monitored target genuinely moved (unmonitored, held, or made available), and a missing
  # row is a stale entry.
  defp ineligible_reason(%Intent{kind: :book_target, target_id: target_id}) do
    case Repo.get(BookTarget, target_id) do
      nil -> :stale_entry
      %BookTarget{status: :monitored} -> :download_intent_busy
      %BookTarget{} -> :stale_target
    end
  end

  defp ineligible_reason(%Intent{}), do: :stale_target

  defp submission_target_active?(%Intent{kind: :movie, target_id: movie_id}) do
    case Repo.get(Movie, movie_id) do
      %Movie{status: status} ->
        status in [:requested, :searching, :no_match, :search_failed, :import_failed, :available]

      nil ->
        false
    end
  end

  # A book target is submittable only while `:monitored` and holding no grab. The grab check is
  # what stops a reserved-but-unsubmitted intent from adding a second download after an operator
  # grabbed something else for the same target; `:monitored` is what stops one whose target was
  # unmonitored, held, or already made available mid-flight.
  defp submission_target_active?(%Intent{kind: :book_target, target_id: target_id}) do
    case Repo.get(BookTarget, target_id) do
      %BookTarget{status: :monitored} -> is_nil(Books.Grabs.for_target(target_id))
      _held_unmonitored_available_or_missing -> false
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
    case Books.Grabs.create(target_id, remote_id, intent.protocol, intent.release["title"]) do
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

      %Movie{status: status} = movie when status in [:requested, :searching] ->
        attach_movie(intent, movie, %{status: :downloading})

      %Movie{status: status} = movie when status in [:no_match, :search_failed, :import_failed] ->
        attach_movie(intent, movie, %{status: :downloading, search_attempts: 0})

      %Movie{status: :available} = movie ->
        attach_movie(intent, movie, %{status: :upgrading})

      nil ->
        cleanup_failed_ownership(intent, :stale_entry)

      _ ->
        cleanup_failed_ownership(intent, :stale_target)
    end
  end

  defp attach_movie(intent, movie, attrs) do
    attrs =
      Map.merge(attrs, %{
        download_id: intent.remote_id,
        download_protocol: intent.protocol,
        release_title: intent.release["title"],
        release_policy_snapshot: intent.release_policy_snapshot,
        import_attempts: 0
      })

    case Catalog.transition(movie, attrs, expect: movie.status) do
      {:ok, updated} -> complete_intent(intent, updated)
      {:error, _} -> cleanup_failed_ownership(intent, :stale_target)
    end
  rescue
    Ecto.StaleEntryError -> cleanup_failed_ownership(intent, :stale_entry)
  end

  defp reconcile_episodes(%Intent{remote_id: remote_id} = intent) do
    case Repo.get_by(Grab, download_id: remote_id, download_protocol: intent.protocol) do
      %Grab{} = grab ->
        complete_intent(intent, grab)

      nil ->
        result =
          if is_nil(intent.mapping_snapshot) and is_nil(intent.release_policy_snapshot) do
            Catalog.create_grab(
              remote_id,
              intent.protocol,
              intent.episode_ids,
              intent.release["title"],
              reset_attempts: true,
              allow_available: operator_initiated?(intent),
              arbitrate_at_import: arbitrate_at_import?(intent)
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
  """
  def start(%Movie{} = movie) do
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil -> do_start(movie)
      intent -> reconcile_intent(intent)
    end
  end

  defp do_start(movie) do
    # Every transition below is guarded on the status this unit read (expect:) so a
    # user cancel landing during the indexer/client I/O is never overwritten; a
    # {:error, :stale_status} skips the unit — the next tick re-derives.
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <-
           Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id},
             expect: movie.status
           ) do
      case search_movie(movie, imdb_id) do
        {:ok, release} ->
          grab_if_space(movie, release)

        :no_match ->
          Catalog.transition(
            movie,
            %{status: :no_match, release_policy_snapshot: nil},
            expect: movie.status
          )

        :no_language_match ->
          park_no_language(movie)

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

  defp search_movie(movie, imdb_id) do
    opts =
      [
        protocols: available_protocols(),
        preferred_language: movie.preferred_language,
        original_language: movie.original_language,
        release_blocklist: Catalog.blocked_release_titles(movie)
      ] ++ Acquisition.band_opts(:movies)

    summary = Catalog.media_profile_summary(movie)

    case summary.effective do
      :anime ->
        anime_movie_result(movie, imdb_id, Catalog.anime_movie_acquisition_context(movie), opts)

      :standard ->
        result = standard_movie_result(movie, imdb_id, opts)

        if result == :no_match and MediaProfile.auto_anime_fallback?(summary),
          do:
            anime_movie_result(
              movie,
              imdb_id,
              Catalog.anime_movie_acquisition_context(movie),
              opts
            ),
          else: result
    end
  end

  # A profile switched back to Standard must not keep a stale Anime hold marker. A nil imdb_id
  # (TMDB publishes none for this title) degrades to the guarded free-text search — see issue #195.
  defp standard_movie_result(movie, imdb_id, opts) do
    Catalog.set_anime_hold(movie, nil)

    if imdb_id,
      do: Acquisition.best_release(imdb_id, opts),
      else: Acquisition.best_release_by_title(movie.title, movie.year, opts)
  end

  defp anime_movie_result(movie, imdb_id, context, opts) do
    case AnimePreferences.resolve(movie, Settings.anime_defaults()) do
      {:ok, policy} ->
        Catalog.set_anime_hold(movie, nil)

        Acquisition.best_anime_movie(
          imdb_id,
          context,
          opts ++ AnimePreferences.selection_opts(policy)
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

  @doc """
  After a successful import, removes the source download when the `move_on_import` setting is
  on. Usenet-only (an allowlist, so a nil/unknown protocol no-ops) — torrents are never
  auto-removed so seeding survives. Two independent best-effort removals:

  1. Asks the client to drop its tracked job (only when a `download_id` is present) — cleans up
     history/queue metadata when the client still has it.
  2. Deletes `content_path` directly via `Cinder.Library.delete_download_source/1` — the whole
     per-operation directory or lone file the download client delivered. This is authoritative
     regardless of whether the client's history entry still exists: a client (e.g. SABnzbd with a
     short history retention) that has already evicted the job silently no-ops on its own remove,
     so on-disk cleanup can't depend on that history surviving (issue #115).

  A failure in either is logged, never propagated. Always `:ok`.
  """
  def remove_after_import(protocol, download_id, content_path) do
    move_on_import? = Application.get_env(:cinder, :move_on_import, false)

    if move_on_import? and protocol == :usenet do
      maybe_remove_client(protocol, download_id)
      best_effort_delete_source(content_path)
    end

    :ok
  end

  defp maybe_remove_client(_protocol, download_id) when download_id in [nil, ""], do: :ok

  defp maybe_remove_client(protocol, download_id) do
    case client_for(protocol) do
      {:ok, client} -> best_effort_remove(client, download_id)
      :error -> :ok
    end
  end

  defp best_effort_delete_source(content_path) do
    case Library.delete_download_source(content_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "download source delete failed for #{inspect(content_path)}: #{inspect(reason)}"
        )

        :ok
    end
  catch
    kind, value ->
      Logger.warning(
        "download source delete raised for #{inspect(content_path)}: #{inspect({kind, value})}"
      )

      :ok
  end

  @doc """
  Removes a tracked client download best-effort: logs (and swallows) an `{:error,_}`
  return OR a raised/thrown client failure, always returning `:ok` so a misconfigured
  client can never block a delete/reap or unwind a poller. Shared by the delete/reap
  paths (`Cinder.Catalog`) and the post-import remove.
  """
  def best_effort_remove(client, id) do
    case client.remove(id, delete_files: true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("client remove failed for download #{inspect(id)}: #{inspect(reason)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning(
        "client remove raised for download #{inspect(id)}: #{inspect({kind, value})}"
      )

      :ok
  end

  defp park_no_language(movie) do
    with {:ok, parked} <-
           Catalog.transition(
             movie,
             %{status: :no_match, release_policy_snapshot: nil},
             expect: movie.status
           ) do
      Notifier.notify({:movie_failed, parked, :no_language_match})
      {:ok, parked}
    end
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

  # Pre-grab disk guard: don't hand a release to the client when no download root can hold it. The
  # poller treats {:insufficient_disk_space, _} as a skip (no attempt burned, no park) — space may
  # free up.
  defp grab_if_space(movie, release) do
    if Cinder.Disk.grab_space_available?(release.size),
      do: add_to_client(movie, release),
      else: {:error, {:insufficient_disk_space, release.size}}
  end

  defp add_to_client(movie, release) do
    grab_movie(movie, release)
  end
end
