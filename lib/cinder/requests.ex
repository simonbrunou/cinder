defmodule Cinder.Requests do
  @moduledoc "Request/approval gate: the single caller allowed to create a movie row from a user action."
  import Ecto.Query
  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.User
  alias Cinder.Audit
  alias Cinder.Books
  alias Cinder.Books.Work
  alias Cinder.Catalog
  alias Cinder.Catalog.Profile
  alias Cinder.GuardedWrite
  alias Cinder.LibraryKind
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests.{Approval, Request, RequestTransition, Target}
  alias Cinder.Settings
  alias Cinder.Util

  @topic "requests"

  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, msg)

  def assign_profile(%Request{} = request, nil) do
    request
    |> Request.profile_changeset(%{proposed_profile_id: nil, proposed_media_profile: nil})
    |> Repo.update()
  end

  def assign_profile(%Request{} = request, %Profile{id: id}) do
    expected_kind = request_kind(request)

    case Catalog.get_profile(id) do
      %Profile{kind: ^expected_kind} = profile ->
        request
        |> Request.profile_changeset(%{
          proposed_profile_id: profile.id,
          proposed_media_profile: profile.handling
        })
        |> Repo.update()

      %Profile{} ->
        {:error, :wrong_profile_kind}

      nil ->
        {:error, :unknown_profile}
    end
  end

  def list_pending do
    Repo.all(
      from r in Request, where: r.status == :pending, order_by: [asc: r.id], preload: [:user]
    )
  end

  @doc "Count of requests awaiting admin approval — a light query behind the admin nav badge."
  def count_pending do
    Repo.aggregate(from(r in Request, where: r.status == :pending), :count)
  end

  @doc """
  Announce that a user's requests vanished out-of-band — the FK cascade of a user deletion
  removes them without any per-request event, which would leave the pending nav badge and the
  approval queue stale. The rows are already gone, so there is no payload; subscribers re-read.
  Post-commit only.
  """
  def announce_pruned_for_deleted_user do
    broadcast({:request_deleted, nil})
  end

  def list_requests do
    Repo.all(from r in Request, order_by: [desc: r.id], preload: [:user])
  end

  @doc "Fetches one request without raising on a missing id."
  def fetch_request(id) when is_integer(id) and id > 0 do
    case Repo.get(Request, id) do
      %Request{} = request -> {:ok, request}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  A page of the request queue projected to JSON-ready maps for the household `/api/v1` scope,
  newest first. Datetimes are ISO-8601 strings, like `export_for_user/1`.

  Deliberately omits the requester and the admin's `denial_reason`, so a session-less caller
  gets no personal data. It is NOT scoped by status or user: this is the whole admin queue, which
  is why `CinderWeb.ApiController` documents the key as an admin credential. `limit`/`offset` are
  clamped by the caller.
  """
  @spec list_for_api(pos_integer(), non_neg_integer()) :: [map()]
  def list_for_api(limit, offset) do
    Request
    |> from(order_by: [desc: :id], limit: ^limit, offset: ^offset, preload: [:proposed_profile])
    |> Repo.all()
    |> Enum.map(&for_api/1)
  end

  @doc "Projects one request to the same personal-data-free shape returned by `list_for_api/2`."
  def for_api(%Request{} = request) do
    request = Repo.preload(request, :proposed_profile)

    %{
      id: request.id,
      status: request.status,
      target_type: request.target_type,
      target_id: request.target_id,
      season_number: request.season_number,
      media_kind: request.media_kind,
      title: request.title,
      year: request.year,
      profile: profile_identity(request.proposed_profile),
      requested_at: iso(request.inserted_at)
    }
  end

  defp profile_identity(nil), do: nil

  defp profile_identity(profile) do
    Map.take(profile, [:id, :name, :kind, :handling])
  end

  @doc "Total number of requests of any status — the page envelope for `list_for_api/2`."
  @spec count_requests() :: non_neg_integer()
  def count_requests, do: Repo.aggregate(Request, :count)

  def list_for_user(%User{id: id}) do
    Repo.all(from r in Request, where: r.user_id == ^id, order_by: [desc: r.id])
  end

  @doc """
  The caller's OWN requests, projected to JSON-ready maps for a GDPR Art.15/20 data export.
  Own data only — scoped by user id, like `list_for_user/1`. Datetimes are ISO-8601 strings.
  """
  def export_for_user(%User{} = user) do
    user
    |> list_for_user()
    |> Enum.map(fn r ->
      %{
        status: r.status,
        target_type: r.target_type,
        target_id: r.target_id,
        season_number: r.season_number,
        media_kind: r.media_kind,
        title: r.title,
        year: r.year,
        denial_reason: r.denial_reason,
        inserted_at: iso(r.inserted_at),
        updated_at: iso(r.updated_at)
      }
    end)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  @doc """
  Users with an approved request for this movie (by `tmdb_id`) — every requester who
  should hear when it becomes available or fails, not just the first. `Cinder.Notifier.Email`
  uses this to fan a `:movie_available`/`:movie_failed` event out to each of them.
  """
  @spec approved_requesters_for_movie(integer()) :: [User.t()]
  def approved_requesters_for_movie(tmdb_id) do
    Repo.all(
      from r in Request,
        join: u in assoc(r, :user),
        where: r.target_type == "movie" and r.target_id == ^tmdb_id and r.status == :approved,
        distinct: true,
        order_by: [asc: u.id],
        select: u
    )
  end

  @doc """
  Users with an approved request for this season (by the series' `tmdb_id` + `season_number`)
  — the season/TV analog of `approved_requesters_for_movie/1`.
  """
  @spec approved_requesters_for_season(integer(), integer()) :: [User.t()]
  def approved_requesters_for_season(tmdb_id, season_number) do
    Repo.all(
      from r in Request,
        join: u in assoc(r, :user),
        where:
          r.target_type == "season" and r.target_id == ^tmdb_id and
            r.season_number == ^season_number and r.status == :approved,
        distinct: true,
        order_by: [asc: u.id],
        select: u
    )
  end

  @doc """
  Users with an approved request for this book (by `Cinder.Books.Work` id + media kind) — the
  books analog of `approved_requesters_for_movie/1`.

  `media_kind` is part of the key rather than decoration: one work carries an `:ebook` and an
  `:audiobook` target independently, and the household member who asked for the audiobook has not
  been served by the e-book landing.
  """
  @spec approved_requesters_for_book(integer(), atom()) :: [User.t()]
  def approved_requesters_for_book(work_id, media_kind) do
    Repo.all(
      from r in Request,
        join: u in assoc(r, :user),
        where:
          r.target_type == "book" and r.target_id == ^work_id and
            r.media_kind == ^media_kind and r.status == :approved,
        distinct: true,
        order_by: [asc: u.id],
        select: u
    )
  end

  def create_request(%User{} = user, attrs) do
    with {:ok, attrs} <- normalize_request_profile(attrs) do
      case Repo.get(User, user.id) do
        %User{} = current ->
          create_for_current_user(current, attrs)

        nil ->
          {:error, :invalid_requester}
      end
    end
  end

  defp create_for_current_user(current, attrs) do
    auto_approve? = current.role == :admin or Settings.auto_approve_all?()

    if current.role != :admin and over_quota?(current, auto_approve?) do
      {:error, :quota_exceeded}
    else
      with {:ok, attrs} <- snapshot_request(attrs) do
        create_request_for(current, attrs, auto_approve?)
      end
    end
  end

  # A discovery surface holds a provider resolution, not a work id, so it hands the resolution
  # over and this folds it into the catalog here — *after* `create_for_current_user/2`'s quota
  # check, and nowhere else. Importing on the caller's side instead would let a user who is over
  # quota grow `book_works` and its editions without bound on every refused press, which is
  # exactly why the movie path creates its row inside this module too.
  #
  # `import_resolution/1` is idempotent, so a re-request of a known work updates in place.
  defp snapshot_request(%{target_type: "book", resolution: resolution} = attrs) do
    case Books.import_resolution(resolution) do
      {:ok, %Work{} = work} ->
        attrs
        |> Map.delete(:resolution)
        |> Map.put(:target_id, work.id)
        |> snapshot_request()

      {:error, _reason} ->
        {:error, :unknown_work}
    end
  end

  # A book's title comes from Cinder's own catalog, not a provider: `target_id` is a
  # `book_works.id` that B2's identity resolution already wrote. A missing work fails closed
  # rather than inserting a title-less request the approval queue could not render.
  defp snapshot_request(%{target_type: "book", target_id: work_id} = attrs) do
    case Repo.get(Work, work_id) do
      %Work{} = work ->
        {:ok,
         attrs
         |> Map.put(:title, work.title)
         |> Map.put(:year, year_of(work.first_published_on))
         |> Map.put(:localizations, %{})}

      nil ->
        {:error, :unknown_work}
    end
  end

  defp snapshot_request(%{target_type: type, target_id: tmdb_id} = attrs) do
    result =
      case type do
        "movie" -> Catalog.get_movie(tmdb_id)
        type when type in ["series", "season"] -> Catalog.tmdb_series(tmdb_id)
        _ -> {:error, :unsupported_target}
      end

    case result do
      {:ok, info} ->
        {:ok,
         attrs
         |> Map.put(:title, info.title)
         |> Map.put(:localizations, Map.get(info, :localizations, %{}))}

      {:error, _} ->
        {:ok, Map.put(attrs, :localizations, %{})}
    end
  end

  defp year_of(%Date{year: year}), do: year
  defp year_of(nil), do: nil

  defp create_request_for(user, attrs, true) do
    approver_id = if user.role == :admin, do: user.id, else: nil

    with {:ok, adapter} <- Approval.adapter(attrs),
         {:ok, profile} <- auto_approval_profile(attrs) do
      approve_target({:insert, user, attrs, approver_id}, adapter, profile)
    end
  end

  defp create_request_for(user, attrs, false), do: create_pending(user, attrs)

  # Insert, then re-count inside one transaction. SQLite serializes write transactions,
  # so the post-insert count sees any concurrently-committed pending row — closing the
  # check-then-insert race a pre-insert count would leave open. (A truly concurrent test
  # isn't possible under the single-connection Sandbox; the sequential cases cover the logic.)
  defp create_pending(user, attrs) do
    Repo.transaction(
      fn -> insert_pending(user, attrs) end,
      mode: :immediate
    )
    |> Util.tap_ok(fn request ->
      broadcast({:request_created, request})
      # Only this path notifies. The other two {:request_created, _} broadcasts (an approval
      # revert and reopen_request/2) are admin-initiated, so telling the admin "someone is
      # waiting" would just be echoing their own click back at them.
      # `user` is already in scope, so attributing the event needs no preload.
      Notifier.notify({:request_created, %{request | user: user}})
    end)
  end

  defp insert_pending(user, attrs) do
    case Repo.get(User, user.id) do
      nil ->
        Repo.rollback(:invalid_requester)

      current ->
        with {:ok, request} <-
               %Request{}
               |> Request.create_changeset(
                 Map.merge(attrs, %{user_id: current.id, status: :pending})
               )
               |> Repo.insert(),
             false <- pending_over_quota?(current) do
          request
        else
          true -> Repo.rollback(:quota_exceeded)
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp over_quota?(%User{request_quota: nil}, _auto_approve?), do: false

  defp over_quota?(%User{request_quota: quota, id: id}, auto_approve?) do
    outstanding_count(id, auto_approve?) >= quota
  end

  defp pending_over_quota?(%User{request_quota: nil}), do: false

  # Counts AFTER the insert, so the just-inserted row is included — hence `>` not `>=`.
  defp pending_over_quota?(%User{request_quota: quota, id: id}) do
    pending_count(id) > quota
  end

  # The auto-approve counterpart of `pending_over_quota?/1`, run by `quota_check/1` inside the
  # approval transaction AFTER the request's target is persisted (#650), so the new request is counted
  # unless its target is already settled. Re-reads the user so a quota edited since the pre-check
  # is honoured; `>` because the new row is included. Admins are never limited.
  defp approved_quota_check(%User{role: :admin}), do: :ok

  defp approved_quota_check(%User{id: id}) do
    case Repo.get(User, id) do
      nil ->
        {:error, :invalid_requester}

      %User{request_quota: nil} ->
        :ok

      %User{role: :admin} ->
        :ok

      %User{request_quota: quota} ->
        if outstanding_count(id, true) > quota, do: {:error, :quota_exceeded}, else: :ok
    end
  end

  defp pending_count(user_id),
    do:
      Repo.aggregate(
        from(r in Request, where: r.user_id == ^user_id and r.status == :pending),
        :count
      )

  # The quota is a "concurrent outstanding requests" limit. A pending request is outstanding;
  # under `auto_approve_all` nothing ever sits pending, so an approved request whose target has
  # not landed yet is outstanding too (#650). With auto-approve off the count is pending-only,
  # as before.
  defp outstanding_count(user_id, false), do: pending_count(user_id)

  defp outstanding_count(user_id, true),
    do: pending_count(user_id) + outstanding_approved_count(user_id)

  # One user's approved requests whose target is still outstanding: not landed, and not settled by
  # an operator. `Cinder.Requests.Target` holds the rule beside the watchable rule My requests,
  # Discover and Issues read. It is deliberately broader: an upgrade held for verification and a
  # cancelled movie stop holding a slot without ever being watchable. Excluding settled targets
  # here, rather than reaping the request in Catalog/Books, leaves the requester's history intact.
  # Counts rows, not targets.
  defp outstanding_approved_count(user_id) do
    from(r in Request, where: r.user_id == ^user_id and r.status == :approved)
    |> Repo.all()
    |> Target.resolve()
    |> Enum.count(fn {_request, target} -> target.outstanding? end)
  end

  # The profile is checked against the request's kind before the provider round-trips, then again
  # inside the approval transaction.
  def approve_request(%Request{status: :pending} = request, %User{} = admin, %Profile{} = profile) do
    with {:ok, adapter} <- Approval.adapter(request),
         {:ok, profile} <- current_profile(profile, request_kind(request)) do
      approve_target({:flip, request, admin}, adapter, profile)
    end
  end

  def approve_request(
        %Request{status: :pending} = request,
        %User{} = admin,
        profile
      )
      when profile in [:standard, :anime] do
    with {:ok, named} <- profile_for_handling(request, profile) do
      approve_request(request, admin, named)
    end
  end

  def approve_request(%Request{status: :pending}, _admin, _profile),
    do: {:error, :invalid_media_profile}

  def approve_request(%Request{}, _admin, _profile), do: {:error, :not_pending}

  # The one approval transaction, for an admin approval (`:flip`, a pending request) and an
  # auto-approval (`:insert`, a request filed already approved), and for every request target kind
  # through its `Cinder.Requests.Approval` adapter. The order is the gate:
  #
  # 1. The adapter prepares before the transaction, so no provider round-trip holds the write lock.
  # 2. `:immediate` takes the write lock at BEGIN: the profile read below would otherwise make this
  #    a deferred read-then-write transaction, which SQLite refuses with SQLITE_BUSY rather than
  #    waiting when another write commits in between.
  # 3. The profile is re-read, so the approval writes the profile the DB holds now.
  # 4. The request write comes before the target: a racing deny makes the flip fail with
  #    `:not_pending` before any catalog row, alias or book target is written.
  # 5. The quota re-count runs after the target exists, so the new request counts unless its
  #    target is already settled (#650).
  # 6. Only after commit: the target's own publish (a book target's guarded write publishes as
  #    the frame commits), then the approval announcement.
  defp approve_target(write, adapter, profile) do
    with {:ok, prepared} <- adapter.prepare(write_source(write), profile),
         {:ok, {approved, created}} <-
           GuardedWrite.transaction(
             fn -> approve_in_transaction(write, adapter, prepared, profile) end,
             mode: :immediate
           ) do
      adapter.publish(created, approved)
      announce_approved(approved)
      {:ok, approved}
    end
  end

  defp approve_in_transaction(write, adapter, prepared, profile) do
    with {:ok, profile} <- reread_profile(profile, write_source(write)),
         {:ok, approved} <- write_request(write, profile),
         {:ok, created} <- adapter.create(prepared, profile),
         :ok <- quota_check(write) do
      {approved, created}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write_source({:flip, request, _admin}), do: request
  defp write_source({:insert, _user, attrs, _approver_id}), do: attrs

  defp reread_profile(nil, _source), do: {:ok, nil}

  defp reread_profile(%Profile{} = profile, source),
    do: current_profile(profile, request_kind(source))

  defp write_request({:flip, request, admin}, profile) do
    flip_pending(
      request,
      Map.merge(%{status: :approved, approved_by_id: admin.id}, profile_attrs(profile))
    )
  end

  # The insert reaches Ecto's `to_constraints`, but ecto_sqlite3 translates every FK violation to
  # `[foreign_key: nil]` (no column name from SQLite), and Ecto requires the registered constraint
  # name to match — a nil name never matches, so `Repo.insert/1` raises `Ecto.ConstraintError`
  # regardless of a declared `foreign_key_constraint/2`. The insert's counterpart of the flip's
  # `RequestTransition.refusal/2`: a concurrent deletion of the requester or (for an admin
  # auto-approval) the approver — the same row for an admin request — is refused, not raised, and
  # `approve_in_transaction/4` rolls back on it.
  defp write_request({:insert, user, attrs, approver_id}, profile) do
    %Request{}
    |> Request.create_changeset(
      attrs
      |> Map.merge(%{user_id: user.id, status: :approved, approved_by_id: approver_id})
      |> Map.merge(profile_attrs(profile))
    )
    |> Repo.insert()
  rescue
    error in Ecto.ConstraintError -> refuse_insert(error, __STACKTRACE__, user, approver_id)
  end

  defp profile_attrs(nil), do: %{}

  defp profile_attrs(%Profile{} = profile),
    do: %{proposed_profile_id: profile.id, proposed_media_profile: profile.handling}

  # The quota decision. An auto-approval adds a row the quota counts, so it re-counts (#650). An
  # admin approval is the admin's own decision on a row the quota already counted while pending,
  # and it never grows the count: the pending row becomes an approved one that counts only while
  # its target is outstanding, and only under `auto_approve_all`. So a quota lowered after the
  # request was filed never blocks the admin.
  defp quota_check({:flip, _request, _admin}), do: :ok
  defp quota_check({:insert, user, _attrs, _approver_id}), do: approved_quota_check(user)

  def deny_request(%Request{status: :pending} = request, %User{} = admin, reason) do
    request
    |> flip_pending(%{status: :denied, denial_reason: reason, approved_by_id: admin.id})
    |> Util.tap_ok(&announce_denied(&1, reason))
  end

  def deny_request(%Request{}, _admin, _reason), do: {:error, :not_pending}

  # The admin's decision on a pending request, as a guarded write on `status == :pending`: two
  # racing admin sessions (a slow bulk async approve against a concurrent deny) can't silently
  # reverse each other's committed decision. A miss is `:not_pending`. A trigger or FK refusal
  # (`RequestTransition.refusal/2`) inside the approval's frame rolls the whole approval back.
  defp flip_pending(%Request{} = request, attrs) do
    case GuardedWrite.write(RequestTransition, request, attrs, status: :pending) do
      {:error, :stale_status} -> {:error, :not_pending}
      result -> result
    end
  end

  # Rescue seam for the auto-approval request insert (`write_request/2`): a concurrent deletion
  # of the requester or approver during the provider round-trips before the write. For an admin
  # request the deleted row is both, so the approver check goes first; `Repo.get` costs one
  # query on the rare raise path only. Unrelated `Ecto.ConstraintError`s (a future FK this
  # module gains) re-raise rather than being swallowed as a false refusal.
  defp refuse_insert(error, stacktrace, user, approver_id) do
    cond do
      not is_nil(approver_id) and is_nil(Repo.get(User, approver_id)) ->
        {:error, :approver_deleted}

      is_nil(Repo.get(User, user.id)) ->
        {:error, :invalid_requester}

      true ->
        reraise error, stacktrace
    end
  end

  @doc """
  Reopens a denied request back to `:pending` (clearing the denial reason and
  approver) so an admin can recover from a mistaken deny — the undo path for the
  approval queue. Re-occupies the partial `requests_pending_unique` slot, so it
  returns `{:error, changeset}` if a competing pending row for the same target
  was created in the meantime.
  """
  def reopen_request(%Request{status: :denied} = request, %User{} = _admin) do
    Repo.transaction(
      fn -> reopen_denied_request(Repo.get(Request, request.id)) end,
      mode: :immediate
    )
    |> Util.tap_ok(&broadcast({:request_created, &1}))
  end

  def reopen_request(%Request{}, _admin), do: {:error, :not_denied}

  defp reopen_denied_request(%Request{status: :denied} = current) do
    current
    |> Request.status_changeset(%{
      status: :pending,
      denial_reason: nil,
      approved_by_id: nil
    })
    |> Repo.update()
    |> case do
      {:ok, reopened} -> reopened
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp reopen_denied_request(_request), do: Repo.rollback(:not_denied)

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
            media_kind: fresh.media_kind,
            title: fresh.title
          })

          fresh

        {0, _} ->
          Repo.rollback(:not_found)
      end
    end)
    |> Util.tap_ok(&broadcast({:request_deleted, &1}))
  end

  @doc """
  Cancels the CALLER's own request, but only while it is still `:pending` — the
  self-service counterpart to the admin `delete_request/2`. Ownership and status are
  BOTH enforced by the DELETE's WHERE clause in one atomic statement (no read-then-write
  window a stale UI click could race), so a forged or stale `phx-value-id` can never
  cancel someone else's request, nor one an admin already approved/denied out from under
  the requester in the meantime. Both failure shapes collapse to the same
  `{:error, :not_pending}` — a generic "not currently pending for you" reason, since
  distinguishing "not yours" from "already decided" would leak whether the target row
  exists at all. Not admin-audited: this is a requester acting on their own row, not a
  destructive admin action.

  Non-admins are limited to 10 cancellations per hour (`Cinder.Accounts.IpRateLimiter`'s
  `:request_cancel` bucket, keyed on the user id): each create fires a TMDB lookup and an admin
  notification, and cancelling frees the quota slot, so an unbounded add→cancel loop would flood
  the admin channel. Past the limit the row is left in place and `{:error, :rate_limited}` is
  returned.
  """
  def cancel_own_request(%Request{id: id}, %User{id: user_id} = user) do
    if cancel_limited?(user) do
      {:error, :rate_limited}
    else
      Repo.delete_all(
        from(r in Request,
          where: r.id == ^id and r.user_id == ^user_id and r.status == :pending,
          select: r
        )
      )
      |> case do
        {1, [fresh]} -> {:ok, fresh}
        {0, _} -> {:error, :not_pending}
      end
      |> Util.tap_ok(&broadcast({:request_deleted, &1}))
    end
  end

  defp cancel_limited?(%User{role: :admin}), do: false

  defp cancel_limited?(%User{id: user_id}),
    do: IpRateLimiter.check_and_register(:request_cancel, user_id) == :blocked

  @doc """
  Deletes the `:approved` request row(s) for a catalog target being deleted, joining the
  CALLER's transaction (invoked from `Catalog.delete_movie/3` and `delete_series/3` inside their
  `delete_with_audit` transaction, so a crash can't half-reap). Returns the count deleted.

  Reaps only `:approved` — the one status that records "a media row exists/existed for this",
  which is exactly what goes stale when the media is deleted (a stranded requester behind an
  "Approved" badge with the Add button suppressed). `:pending` (an un-adjudicated ask the deletion
  does not answer — an admin can still approve it, re-creating the title) and `:denied` (a standing
  decision, already re-requestable) are deliberately left untouched.

  `target_types` scopes the polymorphic match: `["movie"]`, or `["series", "season", "episode"]`
  for a series — season/episode requests carry the SERIES' tmdb_id in `target_id` (disambiguated
  by `season_number`), so the whole tree is reaped. `tmdb_id` is the `target_id` to match.

  No broadcast: the delete already announces `{:movie_deleted, id}`/`{:series_deleted, id}`; an open
  `/requests` or `/my-requests` view refreshes on its next load. (ponytail: no live push wired for a
  rare admin action; add one if a stale open queue ever bites.)
  """
  def reap_approved_for_target(target_types, tmdb_id) do
    {count, _} =
      Repo.delete_all(
        from r in Request,
          where:
            r.target_type in ^target_types and r.target_id == ^tmdb_id and r.status == :approved
      )

    count
  end

  # The profile an auto-approval writes: the requester's proposal, re-read so a profile deleted
  # since `normalize_request_profile/1` fails closed rather than leaving the request pointing at
  # nothing. With no proposal, a movie or season is Auto. A book target is useless without a
  # profile — B4 has nothing to score against — so it falls back to the lowest-id `:standard`
  # profile of that media kind, and fails closed when none is configured.
  defp auto_approval_profile(%{proposed_profile_id: id}) when is_integer(id) do
    case Catalog.get_profile(id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :invalid_media_profile}
    end
  end

  defp auto_approval_profile(%{target_type: "book"} = attrs),
    do: profile_for_handling(attrs, :standard)

  defp auto_approval_profile(_attrs), do: {:ok, nil}

  # The only approval announcement, called by `approve_target/3` after commit. Repo.preload is a
  # no-op on an admin approval (the approval queue's query already preloaded :user). An
  # auto-approval builds the struct from a bare insert, so without this a notifier reading
  # `request.user` would raise on %NotLoaded{} — and Notifier.notify/1 swallows raises, so Discord
  # would silently never post for auto-approved requests while working fine for admin-approved ones.
  defp announce_approved(request) do
    request = Repo.preload(request, :user)
    broadcast({:request_approved, request})
    Notifier.notify({:request_approved, request})
  end

  # Mirrors announce_approved/1: preload :user (a no-op on the admin approval-queue path, which
  # already preloaded it) so the Email transport can address the requester, then broadcast for
  # open views and emit the out-of-band notifier event carrying the admin's free-text reason.
  defp announce_denied(request, reason) do
    request = Repo.preload(request, :user)
    broadcast({:request_denied, request})
    Notifier.notify({:request_denied, request, reason})
  end

  defp normalize_request_profile(%{target_type: _type} = attrs) do
    profile_id = Map.get(attrs, :proposed_profile_id)
    handling = Map.get(attrs, :proposed_media_profile)

    cond do
      is_integer(profile_id) and profile_id > 0 ->
        with %Profile{} = profile <- Catalog.get_profile(profile_id),
             true <- profile.kind == request_kind(attrs),
             true <- handling in [nil, profile.handling] do
          {:ok,
           attrs
           |> Map.put(:proposed_profile_id, profile.id)
           |> Map.put(:proposed_media_profile, profile.handling)}
        else
          _ -> {:error, :invalid_media_profile}
        end

      is_nil(profile_id) and handling in [:standard, :anime] ->
        with {:ok, profile} <- profile_for_handling(attrs, handling) do
          {:ok, Map.put(attrs, :proposed_profile_id, profile.id)}
        end

      is_nil(profile_id) and is_nil(handling) ->
        {:ok, attrs}

      true ->
        {:error, :invalid_media_profile}
    end
  end

  defp normalize_request_profile(_attrs), do: {:error, :invalid_media_profile}

  defp profile_for_handling(target, handling) do
    case request_kind(target) do
      nil ->
        {:error, :invalid_media_profile}

      kind ->
        case default_profile_for_handling(Catalog.list_profiles(kind), handling) do
          %Profile{} = profile -> {:ok, profile}
          nil -> {:error, :invalid_media_profile}
        end
    end
  end

  defp default_profile_for_handling(profiles, handling) do
    profiles
    |> Enum.filter(&(&1.handling == handling))
    |> Enum.min_by(& &1.id, fn -> nil end)
  end

  # Takes the request/attrs map, not the target type alone: `"book"` names no profile kind by
  # itself — the (work, media_kind) axis does.
  defp request_kind(%{target_type: "movie"}), do: :movies
  defp request_kind(%{target_type: type}) when type in ["series", "season", "episode"], do: :tv
  # Validated, not merely fetched: this feeds `Catalog.list_profiles/1`, whose head guards on
  # the kind atoms, so a string from a form or a hand-built attrs map would raise instead of
  # yielding the `{:error, :invalid_media_profile}` every other bad-profile input gets.
  defp request_kind(%{target_type: "book"} = target) do
    kind = Map.get(target, :media_kind)
    if kind in LibraryKind.books(), do: kind
  end

  defp request_kind(_target), do: nil

  defp current_profile(%Profile{id: id}, expected_kind) do
    case Catalog.get_profile(id) do
      %Profile{kind: ^expected_kind} = profile -> {:ok, profile}
      _ -> {:error, :invalid_media_profile}
    end
  end
end
