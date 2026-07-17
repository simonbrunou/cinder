defmodule Cinder.Requests do
  @moduledoc "Request/approval gate: the single caller allowed to create a movie row from a user action."
  import Ecto.Query
  require Logger
  alias Cinder.Accounts.User
  alias Cinder.Audit
  alias Cinder.Catalog
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests.Request
  alias Cinder.Settings

  @topic "requests"

  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, msg)

  def list_pending do
    Repo.all(
      from r in Request, where: r.status == :pending, order_by: [asc: r.id], preload: [:user]
    )
  end

  def list_requests do
    Repo.all(from r in Request, order_by: [desc: r.id], preload: [:user])
  end

  def list_for_user(%User{id: id}) do
    Repo.all(from r in Request, where: r.user_id == ^id, order_by: [desc: r.id])
  end

  def create_request(%User{} = user, attrs) do
    if valid_proposed_profile?(attrs) do
      create_request_for(user, attrs, user.role == :admin or Settings.auto_approve_all?())
    else
      {:error, :invalid_media_profile}
    end
  end

  defp create_request_for(user, attrs, true) do
    approver_id = if user.role == :admin, do: user.id, else: nil
    create_approved(user, attrs, approver_id)
  end

  defp create_request_for(user, attrs, false), do: create_pending(user, attrs)

  # Insert, then re-count inside one transaction. SQLite serializes write transactions,
  # so the post-insert count sees any concurrently-committed pending row — closing the
  # check-then-insert race a pre-insert count would leave open. (A truly concurrent test
  # isn't possible under the single-connection Sandbox; the sequential cases cover the logic.)
  defp create_pending(user, attrs) do
    Repo.transaction(fn ->
      with {:ok, request} <-
             %Request{}
             |> Request.create_changeset(Map.merge(attrs, %{user_id: user.id, status: :pending}))
             |> Repo.insert(),
           false <- over_quota?(user) do
        request
      else
        true -> Repo.rollback(:quota_exceeded)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> tap_ok(&broadcast({:request_created, &1}))
  end

  defp over_quota?(%User{request_quota: nil}), do: false

  # Counts AFTER the insert, so the just-inserted row is included — hence `>` not `>=`.
  defp over_quota?(%User{request_quota: quota, id: id}) do
    pending =
      Repo.aggregate(from(r in Request, where: r.user_id == ^id and r.status == :pending), :count)

    pending > quota
  end

  def approve_request(
        %Request{status: :pending, target_type: "movie"} = request,
        %User{} = admin,
        profile
      )
      when profile in [:standard, :anime] do
    with {:ok, prepared} <-
           Catalog.prepare_requested_movie(movie_attrs(request, media_profile: profile)) do
      approve_prepared_movie(request, admin, prepared)
      |> tap_ok(&announce_approved/1)
    end
  end

  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O. The flip
  # runs FIRST (guarded on :pending) so a deny landing during the seconds-long TMDB call
  # can't leave committed series content behind a denied request; a series-creation
  # failure then compensates by putting the request back to :pending.
  def approve_request(
        %Request{status: :pending, target_type: "season"} = request,
        %User{} = admin,
        profile
      )
      when profile in [:standard, :anime] do
    with {:ok, approved} <- flip_pending(request, %{status: :approved, approved_by_id: admin.id}) do
      case create_series_safely(request, profile) do
        {:ok, _series} ->
          announce_approved(approved)
          {:ok, approved}

        {:error, reason} ->
          revert_to_pending(approved)
          {:error, reason}
      end
    end
  end

  def approve_request(%Request{status: :pending}, _admin, _profile),
    do: {:error, :invalid_media_profile}

  def approve_request(%Request{}, _admin, _profile), do: {:error, :not_pending}

  defp approve_prepared_movie(request, admin, prepared) do
    Repo.transaction(fn ->
      # Provider I/O finished before this transaction. Flip first so a racing deny
      # prevents both the movie and its aliases from being written.
      with {:ok, approved} <-
             flip_pending(request, %{status: :approved, approved_by_id: admin.id}),
           {:ok, movie, created} <-
             Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases) do
        {approved, movie, created}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_movie_approval(prepared)
  end

  # The TMDB call runs while the request already reads :approved; a raise/exit here
  # must reach the revert path (not strand the request approved with no series), so
  # every failure mode is normalized to {:error, reason} — loudly: this rescue also
  # swallows genuine bugs, and a silent one would be undebuggable. Known residual: a
  # VM kill (deploy/OOM, or the admin closing the tab mid-bulk killing the linked
  # start_async task) between the flip and the revert strands the request :approved
  # with no series; recovery is delete + re-request (documented on delete_request/2).
  defp create_series_safely(request, profile) do
    Catalog.find_or_create_series_at_requested(
      request.target_id,
      request.season_number,
      request.preferred_language || "original",
      profile
    )
  rescue
    e ->
      Logger.warning("series creation for request #{request.id} raised: #{Exception.message(e)}")

      {:error, e}
  catch
    kind, value ->
      Logger.warning("series creation for request #{request.id} #{kind}: #{inspect(value)}")
      {:error, {kind, value}}
  end

  def deny_request(%Request{status: :pending} = request, %User{} = admin, reason) do
    request
    |> flip_pending(%{status: :denied, denial_reason: reason, approved_by_id: admin.id})
    |> tap_ok(&broadcast({:request_denied, &1}))
  end

  def deny_request(%Request{}, _admin, _reason), do: {:error, :not_pending}

  # Guarded status flip: applies `attrs` only while the row is still :pending in the DB —
  # the UPDATE itself is scoped by status, so two racing admin sessions (e.g. a slow bulk
  # async approve vs a concurrent deny) can't silently reverse each other's committed
  # decision. Validates via the changeset, then writes with one atomic update_all (no
  # read-then-write upgrade window for SQLite to reject).
  defp flip_pending(%Request{} = request, attrs) do
    changeset = Request.status_changeset(request, attrs)

    with %{valid?: true, changes: changes} <- changeset,
         {1, _} <-
           Repo.update_all(
             from(r in Request, where: r.id == ^request.id and r.status == :pending),
             set: Map.to_list(changes) ++ [updated_at: now()]
           ) do
      {:ok, struct(request, changes)}
    else
      {0, _} -> {:error, :not_pending}
      %Ecto.Changeset{} = invalid -> {:error, invalid}
    end
  end

  # Compensation for the season approve path: the series never materialized (e.g. TMDB
  # down), so the approval must not stand. Guarded the same way — only undoes our own
  # flip. The {:request_created, _} broadcast nudges open views to re-read: without it,
  # a view mounted during the approved-then-reverted window would show :approved until
  # the next unrelated request event.
  defp revert_to_pending(%Request{} = request) do
    reverted_to =
      try do
        Repo.update_all(
          from(r in Request, where: r.id == ^request.id and r.status == :approved),
          set: [status: :pending, approved_by_id: nil, updated_at: now()]
        )

        :pending
      rescue
        # ONLY the unique-index collision: the partial requests_pending_unique index
        # covers :pending rows, so a duplicate pending request created while this one
        # was briefly :approved makes the revert collide — fall back to :denied
        # (never indexed, recoverable via Reopen) so the strand stays visible.
        #
        # Match on the MESSAGE, not the class: update_all bypasses Ecto's
        # to_constraints, so a collision surfaces as a raw Exqlite.Error — the same
        # class that also carries a transient SQLITE_BUSY or disk-I/O error. Rescuing
        # the whole class would convert a retryable blip into a permanent :denied, so
        # anything that isn't a UNIQUE violation re-raises and propagates.
        e in [Ecto.ConstraintError, Exqlite.Error] ->
          unless unique_collision?(e), do: reraise(e, __STACKTRACE__)

          Logger.warning(
            "revert_to_pending for request #{request.id} collided " <>
              "(#{Exception.message(e)}); denying instead"
          )

          Repo.update_all(
            from(r in Request, where: r.id == ^request.id and r.status == :approved),
            set: [
              status: :denied,
              denial_reason: "Approval failed: the series could not be created.",
              updated_at: now()
            ]
          )

          :denied
      end

    # Broadcast OUTSIDE the rescued region — a broadcast failure after a successful
    # revert must not re-run the fallback and deny an already-reverted request.
    case reverted_to do
      :pending ->
        broadcast({:request_created, struct(request, status: :pending, approved_by_id: nil)})

      :denied ->
        broadcast({:request_denied, struct(request, status: :denied)})
    end
  end

  # A UNIQUE-index violation (the only revert failure we down-convert to :denied),
  # as opposed to a transient busy / disk-I/O Exqlite.Error that must propagate.
  defp unique_collision?(e), do: Exception.message(e) =~ "UNIQUE constraint failed"

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

  @doc """
  Reopens a denied request back to `:pending` (clearing the denial reason and
  approver) so an admin can recover from a mistaken deny — the undo path for the
  approval queue. Re-occupies the partial `requests_pending_unique` slot, so it
  returns `{:error, changeset}` if a competing pending row for the same target
  was created in the meantime.
  """
  def reopen_request(%Request{status: :denied} = request, %User{} = _admin) do
    request
    |> Request.status_changeset(%{status: :pending, denial_reason: nil, approved_by_id: nil})
    |> Repo.update()
    |> tap_ok(&broadcast({:request_created, &1}))
  end

  def reopen_request(%Request{}, _admin), do: {:error, :not_denied}

  @doc """
  Deletes a request as an admin and records an `admin_audit` row in the same
  transaction.

  No FK links a request to the catalog row it may have spawned, so deleting a
  request does NOT remove an approved movie/series. Deleting a non-pending
  (denied/approved) request also re-opens the partial `requests_pending_unique`
  index, so the same title becomes requestable again. The UI surfaces both as a
  warning (see `CinderWeb.RequestsLive`); this function does not undo either.
  """
  def delete_request(%Request{} = request, %User{} = admin) do
    Repo.transaction(fn ->
      # One atomic DELETE ... RETURNING (select: r): the audit records the row's
      # ACTUAL state at delete time — the caller's struct is a rendered snapshot
      # whose status may be stale. 0 rows -> {:error, :not_found} with NO audit row
      # and NO broadcast: the losing admin in a double-delete race must not log a
      # delete that never happened.
      case Repo.delete_all(from(r in Request, where: r.id == ^request.id, select: r)) do
        {1, [fresh]} ->
          Audit.log_or_rollback(admin, "delete_request", fresh, %{
            status: fresh.status,
            target_type: fresh.target_type,
            target_id: fresh.target_id,
            title: fresh.title
          })

          fresh

        {0, _} ->
          Repo.rollback(:not_found)
      end
    end)
    |> tap_ok(&broadcast({:request_deleted, &1}))
  end

  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O.
  defp create_approved(user, %{target_type: "season"} = attrs, approver_id) do
    with {:ok, _series} <-
           Catalog.find_or_create_series_at_requested(
             attrs.target_id,
             attrs[:season_number],
             attrs[:preferred_language] || "original",
             attrs[:proposed_media_profile] || :auto
           ),
         {:ok, request} <-
           %Request{}
           |> Request.create_changeset(
             Map.merge(attrs, %{user_id: user.id, status: :approved, approved_by_id: approver_id})
           )
           |> Repo.insert() do
      announce_approved(request)
      {:ok, request}
    end
  end

  defp create_approved(user, attrs, approver_id) do
    profile = attrs[:proposed_media_profile] || :auto

    with {:ok, prepared} <-
           Catalog.prepare_requested_movie(movie_attrs(attrs, media_profile: profile)) do
      insert_approved_movie(user, attrs, approver_id, prepared)
      |> tap_ok(&announce_approved/1)
    end
  end

  defp insert_approved_movie(user, attrs, approver_id, prepared) do
    Repo.transaction(fn ->
      # Creation is announced post-commit, in finalize_movie_approval — nothing here broadcasts.
      with {:ok, request} <-
             %Request{}
             |> Request.create_changeset(
               Map.merge(attrs, %{
                 user_id: user.id,
                 status: :approved,
                 approved_by_id: approver_id
               })
             )
             |> Repo.insert(),
           {:ok, movie, created} <-
             Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases) do
        {request, movie, created}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_movie_approval(prepared)
  end

  # Post-commit seam shared by both movie-approval transactions above. Runs AFTER the
  # transaction commits — Catalog.apply_confirmed_media/3 must not run inside it (a fill/confirm
  # failure must not roll back the already-committed movie/request write). Both fields stay
  # detail-page-editable afterward, so a failure here only logs. Only the :existing clause
  # confirms/fills; a :created movie needs neither.

  # :created — a fresh insert already carries the requester's profile and pick
  # (Movie.changeset casts both from the create attrs), so there is nothing to confirm or
  # fill: just announce, post-commit. Residual (accepted): the payload is the txn struct, so
  # a delete landing in the commit→broadcast gap would be announced after its own
  # {:movie_deleted} and upserted back by open views until remount — a sub-ms window
  # that would cost a reload per fresh approval to close.
  defp finalize_movie_approval({:ok, {approved, movie, :created}}, _prepared) do
    Catalog.broadcast_movie_created(movie)
    {:ok, approved}
  end

  # :existing — re-read post-commit: the txn struct is a stale snapshot the moment it
  # commits — an edit (or delete) landing before this reload wins over the requester's
  # confirm+fill. An edit in the reload→update window can still lose (no optimistic lock);
  # accepted at household scale.
  defp finalize_movie_approval({:ok, {approved, movie, :existing}}, prepared) do
    case Repo.reload(movie) do
      nil ->
        Logger.warning("movie #{movie.id} (request #{approved.id}) deleted before confirm+fill")

      fresh ->
        confirm_and_fill(fresh, approved, prepared)
    end

    {:ok, approved}
  end

  defp finalize_movie_approval({:error, _reason} = error, _prepared), do: error

  defp confirm_and_fill(movie, approved, prepared) do
    case Catalog.apply_confirmed_media(
           movie,
           prepared.attrs.media_profile,
           prepared.attrs.preferred_language
         ) do
      {:ok, _movie} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "apply_confirmed_media for movie #{movie.id} (request #{approved.id}) failed: " <>
            inspect(reason)
        )
    end
  end

  defp announce_approved(request) do
    broadcast({:request_approved, request})
    Notifier.notify({:request_approved, request})
  end

  # Accepts a %Request{} or a plain attrs map — Map.get works on both.
  defp movie_attrs(source, overrides) do
    Map.merge(
      %{
        tmdb_id: Map.get(source, :target_id),
        title: Map.get(source, :title),
        year: Map.get(source, :year),
        poster_path: Map.get(source, :poster_path),
        original_language: Map.get(source, :original_language),
        preferred_language: Map.get(source, :preferred_language) || "original"
      },
      Map.new(overrides)
    )
  end

  defp valid_proposed_profile?(attrs) do
    Map.get(attrs, :proposed_media_profile, Map.get(attrs, "proposed_media_profile")) in [
      nil,
      :standard,
      :anime
    ]
  end

  defp tap_ok({:ok, value} = res, fun) do
    fun.(value)
    res
  end

  defp tap_ok(other, _fun), do: other
end
