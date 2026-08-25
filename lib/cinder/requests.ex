defmodule Cinder.Requests do
  @moduledoc "Request/approval gate: the single caller allowed to create a movie row from a user action."
  import Ecto.Query
  require Logger
  alias Cinder.Accounts.User
  alias Cinder.Audit
  alias Cinder.Books
  alias Cinder.Books.Work
  alias Cinder.Catalog
  alias Cinder.Catalog.Profile
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests.Request
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
    if current.role != :admin and over_quota?(current) do
      {:error, :quota_exceeded}
    else
      with {:ok, attrs} <- snapshot_request(attrs) do
        create_request_for(
          current,
          attrs,
          current.role == :admin or Settings.auto_approve_all?()
        )
      end
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
    create_approved(user, attrs, approver_id)
  end

  defp create_request_for(user, attrs, false), do: create_pending(user, attrs)

  # Insert, then re-count inside one transaction. SQLite serializes write transactions,
  # so the post-insert count sees any concurrently-committed pending row — closing the
  # check-then-insert race a pre-insert count would leave open. (A truly concurrent test
  # isn't possible under the single-connection Sandbox; the sequential cases cover the logic.)
  defp create_pending(user, attrs) do
    Repo.transaction(
      fn ->
        current = Repo.get!(User, user.id)

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
      end,
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

  defp over_quota?(%User{request_quota: nil}), do: false

  defp over_quota?(%User{request_quota: quota, id: id}) do
    pending_count(id) >= quota
  end

  defp pending_over_quota?(%User{request_quota: nil}), do: false

  # Counts AFTER the insert, so the just-inserted row is included — hence `>` not `>=`.
  defp pending_over_quota?(%User{request_quota: quota, id: id}) do
    pending_count(id) > quota
  end

  defp pending_count(user_id),
    do:
      Repo.aggregate(
        from(r in Request, where: r.user_id == ^user_id and r.status == :pending),
        :count
      )

  def approve_request(
        %Request{status: :pending, target_type: "movie"} = request,
        %User{} = admin,
        %Profile{kind: :movies} = profile
      ) do
    with {:ok, profile} <- current_profile(profile, :movies),
         {:ok, prepared} <-
           Catalog.prepare_requested_movie(
             movie_attrs(request, media_profile: profile.handling, profile_id: profile.id)
           ) do
      approve_prepared_movie(request, admin, prepared, profile)
      |> Util.tap_ok(&announce_approved/1)
    end
  end

  def approve_request(
        %Request{status: :pending, target_type: "season"} = request,
        %User{} = admin,
        %Profile{kind: :tv} = profile
      ) do
    preferred = request.preferred_language || "original"

    with {:ok, profile} <- current_profile(profile, :tv),
         {:ok, prepared} <-
           Catalog.prepare_requested_series(request.target_id, preferred, profile.handling) do
      approve_prepared_series(request, admin, prepared, preferred, profile)
    end
  end

  def approve_request(
        %Request{status: :pending, target_type: "book", media_kind: media_kind} = request,
        %User{} = admin,
        %Profile{kind: media_kind} = profile
      )
      when not is_nil(media_kind) do
    with {:ok, profile} <- current_profile(profile, media_kind),
         %Work{} = work <- Repo.get(Work, request.target_id) do
      request
      |> approve_book(admin, work, profile)
      |> Util.tap_ok(&announce_approved/1)
    else
      nil -> {:error, :unknown_work}
      {:error, _reason} = error -> error
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

  # No provider round-trip and no catalog row to create: the work already exists, so flipping the
  # request and arming its target is one transaction. The target broadcast is post-commit.
  defp approve_book(request, admin, work, profile) do
    Repo.transaction(fn ->
      with {:ok, approved} <- flip_pending(request, approval_attrs(admin, profile)),
           {:ok, target} <-
             Books.monitor_target(work, request.media_kind, profile, publish: false) do
        {approved, target}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {approved, target}} ->
        Books.broadcast({:book_target_updated, target})
        {:ok, approved}

      {:error, _reason} = error ->
        error
    end
  end

  defp approve_prepared_movie(request, admin, prepared, profile) do
    Repo.transaction(fn ->
      # Provider I/O finished before this transaction. Flip first so a racing deny
      # prevents both the movie and its aliases from being written.
      with {:ok, profile} <- current_profile(profile, :movies),
           {:ok, approved} <-
             flip_pending(request, approval_attrs(admin, profile)),
           {:ok, movie, created} <-
             Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases),
           pre_request_profile = movie.media_profile,
           {:ok, {movie, profile_changed?}} <- assign_selected_profile(movie, profile) do
        {approved, movie, created, profile_changed?, pre_request_profile}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_movie_approval(prepared)
  end

  defp approve_prepared_series(request, admin, prepared, preferred, profile) do
    Repo.transaction(fn ->
      with {:ok, profile} <- current_profile(profile, :tv),
           {:ok, approved} <- flip_pending(request, approval_attrs(admin, profile)),
           {:ok, series} <-
             Catalog.persist_requested_series(
               prepared,
               request.season_number,
               preferred,
               profile.handling
             ),
           {:ok, {series, _profile_changed?}} <- assign_selected_profile(series, profile) do
        {approved, series}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_series_approval()
  end

  def deny_request(%Request{status: :pending} = request, %User{} = admin, reason) do
    request
    |> flip_pending(%{status: :denied, denial_reason: reason, approved_by_id: admin.id})
    |> Util.tap_ok(&announce_denied(&1, reason))
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

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

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
  """
  def cancel_own_request(%Request{id: id}, %User{id: user_id}) do
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

  defp create_approved(user, %{target_type: "book"} = attrs, approver_id) do
    # Unlike a movie, a book target is useless without a profile — B4 has nothing to score
    # against — so an auto-approval with no proposed profile falls back to the lowest-id
    # `:standard` profile of that media kind, and fails closed when none is configured.
    with {:ok, profile} <- approved_book_profile(attrs),
         %Work{} = work <- Repo.get(Work, attrs.target_id) do
      insert_approved_book(user, attrs, approver_id, work, profile)
    else
      nil -> {:error, :unknown_work}
      {:error, _reason} = error -> error
    end
  end

  defp create_approved(user, %{target_type: "season"} = attrs, approver_id) do
    preferred = attrs[:preferred_language] || "original"
    named = proposed_profile(attrs)
    handling = attrs[:proposed_media_profile] || :auto

    with {:ok, prepared} <-
           Catalog.prepare_requested_series(attrs.target_id, preferred, handling) do
      insert_approved_series(user, attrs, approver_id, prepared, preferred, handling, named)
    end
  end

  defp create_approved(user, attrs, approver_id) do
    named = proposed_profile(attrs)
    handling = attrs[:proposed_media_profile] || :auto

    with {:ok, prepared} <-
           Catalog.prepare_requested_movie(
             movie_attrs(attrs,
               media_profile: handling,
               profile_id: named && named.id
             )
           ) do
      insert_approved_movie(user, attrs, approver_id, prepared, named)
      |> Util.tap_ok(&announce_approved/1)
    end
  end

  defp approved_book_profile(attrs) do
    case proposed_profile(attrs) do
      %Profile{} = profile -> {:ok, profile}
      nil -> profile_for_handling(attrs, :standard)
    end
  end

  defp insert_approved_book(user, attrs, approver_id, work, profile) do
    Repo.transaction(fn ->
      with {:ok, request} <-
             %Request{}
             |> Request.create_changeset(
               Map.merge(attrs, %{
                 user_id: user.id,
                 status: :approved,
                 approved_by_id: approver_id,
                 proposed_profile_id: profile.id,
                 proposed_media_profile: profile.handling
               })
             )
             |> Repo.insert(),
           {:ok, target} <-
             Books.monitor_target(work, attrs.media_kind, profile, publish: false) do
        {request, target}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {approved, target}} ->
        Books.broadcast({:book_target_updated, target})
        announce_approved(approved)
        {:ok, approved}

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_approved_movie(user, attrs, approver_id, prepared, profile) do
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
             Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases),
           pre_request_profile = movie.media_profile,
           {:ok, {movie, profile_changed?}} <- assign_selected_profile(movie, profile) do
        {request, movie, created, profile_changed?, pre_request_profile}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_movie_approval(prepared)
  end

  defp insert_approved_series(
         user,
         attrs,
         approver_id,
         prepared,
         preferred,
         handling,
         profile
       ) do
    Repo.transaction(fn ->
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
           {:ok, series} <-
             Catalog.persist_requested_series(
               prepared,
               attrs[:season_number],
               preferred,
               handling
             ),
           {:ok, {series, _profile_changed?}} <- assign_selected_profile(series, profile) do
        {request, series}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finalize_series_approval()
  end

  defp finalize_series_approval({:ok, {approved, series}}) do
    Catalog.broadcast_series(series.id)
    announce_approved(approved)
    {:ok, approved}
  end

  defp finalize_series_approval({:error, _reason} = error), do: error

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
  defp finalize_movie_approval(
         {:ok, {approved, movie, :created, _profile_changed?, _pre_request_profile}},
         _prepared
       ) do
    Catalog.broadcast_movie_created(movie)
    {:ok, approved}
  end

  # :existing — re-read post-commit: the txn struct is a stale snapshot the moment it
  # commits — an edit (or delete) landing before this reload wins over the requester's
  # confirm+fill. An edit in the reload→update window can still lose (no optimistic lock);
  # accepted at household scale.
  defp finalize_movie_approval(
         {:ok, {approved, movie, :existing, profile_changed?, pre_request_profile}},
         prepared
       ) do
    case Repo.reload(movie) do
      nil ->
        Logger.warning("movie #{movie.id} (request #{approved.id}) deleted before confirm+fill")

      fresh ->
        confirm_and_fill(fresh, approved, prepared, pre_request_profile, profile_changed?)
    end

    {:ok, approved}
  end

  defp finalize_movie_approval({:error, _reason} = error, _prepared), do: error

  defp confirm_and_fill(movie, approved, prepared, pre_request_profile, profile_changed?) do
    preferred = prepared.attrs.preferred_language

    fills_language? =
      movie.preferred_language == "original" and preferred not in [nil, "original"] and
        pre_request_profile != :anime

    result =
      if fills_language? do
        Catalog.apply_confirmed_media(movie, :auto, preferred, pre_request_profile)
      else
        {:ok, movie}
      end

    case result do
      {:ok, _movie} when profile_changed? and not fills_language? ->
        Catalog.broadcast({:movie_updated, movie})

      {:ok, _movie} ->
        :ok

      {:error, reason} ->
        if profile_changed?, do: Catalog.broadcast({:movie_updated, movie})
        log_confirm_failure(movie, approved, reason)
    end
  end

  # Repo.preload is a no-op on the two admin-approval paths (their caller's query already
  # preloaded :user). The two auto-approve paths build the struct from a bare insert, so
  # without this a notifier reading `request.user` would raise on %NotLoaded{} — and
  # Notifier.notify/1 swallows raises, so Discord would silently never post for
  # auto-approved requests while working fine for admin-approved ones.
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
  defp request_kind(%{target_type: "book"} = target), do: Map.get(target, :media_kind)
  defp request_kind(_target), do: nil

  defp current_profile(%Profile{id: id}, expected_kind) do
    case Catalog.get_profile(id) do
      %Profile{kind: ^expected_kind} = profile -> {:ok, profile}
      _ -> {:error, :invalid_media_profile}
    end
  end

  defp proposed_profile(%{proposed_profile_id: id}) when is_integer(id),
    do: Catalog.get_profile(id)

  defp proposed_profile(_attrs), do: nil

  defp approval_attrs(admin, profile) do
    %{
      status: :approved,
      approved_by_id: admin.id,
      proposed_profile_id: profile.id,
      proposed_media_profile: profile.handling
    }
  end

  defp assign_selected_profile(title, nil), do: {:ok, {title, false}}

  defp assign_selected_profile(%{profile_id: id, media_profile: handling} = title, %Profile{
         id: id,
         handling: handling
       }),
       do: {:ok, {title, false}}

  defp assign_selected_profile(title, profile) do
    case Catalog.assign_profile(title, profile, publish: false) do
      {:ok, title} -> {:ok, {title, true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_confirm_failure(movie, approved, reason) do
    Logger.warning(
      "apply_confirmed_media for movie #{movie.id} (request #{approved.id}) failed: " <>
        inspect(reason)
    )
  end
end
