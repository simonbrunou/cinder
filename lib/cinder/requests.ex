defmodule Cinder.Requests do
  @moduledoc "Request/approval gate: the single caller allowed to create a movie row from a user action."
  import Ecto.Query
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
    if user.role == :admin or Settings.auto_approve_all?() do
      approver_id = if user.role == :admin, do: user.id, else: nil
      create_approved(user, attrs, approver_id)
    else
      create_pending(user, attrs)
    end
  end

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

  def approve_request(%Request{status: :pending, target_type: "movie"} = request, %User{} = admin) do
    Repo.transaction(fn ->
      # Flip first (guarded on the DB's :pending), then create the movie: if a racing
      # admin already decided this request, no movie row is ever written.
      with {:ok, approved} <-
             flip_pending(request, %{status: :approved, approved_by_id: admin.id}),
           {:ok, _movie} <- Catalog.find_or_create_at_requested(movie_attrs(request)) do
        approved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap_ok(&announce_approved/1)
  end

  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O. The flip
  # runs FIRST (guarded on :pending) so a deny landing during the seconds-long TMDB call
  # can't leave committed series content behind a denied request; a series-creation
  # failure then compensates by putting the request back to :pending.
  def approve_request(
        %Request{status: :pending, target_type: "season"} = request,
        %User{} = admin
      ) do
    with {:ok, approved} <- flip_pending(request, %{status: :approved, approved_by_id: admin.id}) do
      case create_series_safely(request) do
        {:ok, _series} ->
          announce_approved(approved)
          {:ok, approved}

        {:error, reason} ->
          revert_to_pending(approved)
          {:error, reason}
      end
    end
  end

  def approve_request(%Request{}, _admin), do: {:error, :not_pending}

  # The TMDB call runs while the request already reads :approved; a raise/exit here
  # must reach the revert path (not strand the request approved with no series), so
  # every failure mode is normalized to {:error, reason}.
  defp create_series_safely(request) do
    Catalog.find_or_create_series_at_requested(
      request.target_id,
      request.season_number,
      request.preferred_language || "original"
    )
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
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
    Repo.update_all(
      from(r in Request, where: r.id == ^request.id and r.status == :approved),
      set: [status: :pending, approved_by_id: nil, updated_at: now()]
    )

    broadcast({:request_created, struct(request, status: :pending, approved_by_id: nil)})
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
      # delete_all (not Repo.delete): a concurrent admin may have deleted the same
      # row. 0 rows -> {:error, :not_found} with NO audit row and NO broadcast — the
      # losing admin must not log a delete that never happened.
      case Repo.delete_all(from(r in Request, where: r.id == ^request.id)) do
        {1, _} ->
          Audit.log_or_rollback(admin, "delete_request", request, %{
            status: request.status,
            target_type: request.target_type,
            target_id: request.target_id,
            title: request.title
          })

          request

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
             attrs[:preferred_language] || "original"
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
    Repo.transaction(fn ->
      # A find_or_create failure rolls back (surfacing {:error, changeset}) rather than
      # raising a MatchError out of the LiveView that called it.
      with {:ok, _movie} <- Catalog.find_or_create_at_requested(movie_attrs(attrs)),
           {:ok, request} <-
             %Request{}
             |> Request.create_changeset(
               Map.merge(attrs, %{
                 user_id: user.id,
                 status: :approved,
                 approved_by_id: approver_id
               })
             )
             |> Repo.insert() do
        request
      else
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
    |> tap_ok(&announce_approved/1)
  end

  defp announce_approved(request) do
    broadcast({:request_approved, request})
    Notifier.notify({:request_approved, request})
  end

  # Accepts a %Request{} or a plain attrs map — Map.get works on both.
  defp movie_attrs(source) do
    %{
      tmdb_id: Map.get(source, :target_id),
      title: Map.get(source, :title),
      year: Map.get(source, :year),
      poster_path: Map.get(source, :poster_path),
      original_language: Map.get(source, :original_language),
      preferred_language: Map.get(source, :preferred_language) || "original"
    }
  end

  defp tap_ok({:ok, value} = res, fun) do
    fun.(value)
    res
  end

  defp tap_ok(other, _fun), do: other
end
