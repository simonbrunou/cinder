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
      {:ok, _movie} = Catalog.find_or_create_at_requested(movie_attrs(request))

      request
      |> Request.status_changeset(%{status: :approved, approved_by_id: admin.id})
      |> Repo.update()
      |> case do
        {:ok, r} -> r
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
    |> tap_ok(&announce_approved/1)
  end

  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O.
  def approve_request(
        %Request{status: :pending, target_type: "season"} = request,
        %User{} = admin
      ) do
    with {:ok, _series} <-
           Catalog.find_or_create_series_at_requested(request.target_id, request.season_number),
         {:ok, approved} <-
           request
           |> Request.status_changeset(%{status: :approved, approved_by_id: admin.id})
           |> Repo.update() do
      announce_approved(approved)
      {:ok, approved}
    end
  end

  def approve_request(%Request{}, _admin), do: {:error, :not_pending}

  def deny_request(%Request{status: :pending} = request, %User{} = admin, reason) do
    request
    |> Request.status_changeset(%{
      status: :denied,
      denial_reason: reason,
      approved_by_id: admin.id
    })
    |> Repo.update()
    |> tap_ok(&broadcast({:request_denied, &1}))
  end

  def deny_request(%Request{}, _admin, _reason), do: {:error, :not_pending}

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
      case Repo.delete(request) do
        {:ok, deleted} ->
          Audit.log_or_rollback(admin, "delete_request", deleted, %{
            status: deleted.status,
            target_type: deleted.target_type,
            target_id: deleted.target_id,
            title: deleted.title
          })

          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O.
  defp create_approved(user, %{target_type: "season"} = attrs, approver_id) do
    with {:ok, _series} <-
           Catalog.find_or_create_series_at_requested(attrs.target_id, attrs[:season_number]),
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
      {:ok, _movie} = Catalog.find_or_create_at_requested(movie_attrs_from(attrs))

      %Request{}
      |> Request.create_changeset(
        Map.merge(attrs, %{user_id: user.id, status: :approved, approved_by_id: approver_id})
      )
      |> Repo.insert()
      |> case do
        {:ok, r} -> r
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
    |> tap_ok(&announce_approved/1)
  end

  defp announce_approved(request) do
    broadcast({:request_approved, request})
    Notifier.notify({:request_approved, request})
  end

  defp movie_attrs(%Request{} = r) do
    %{
      tmdb_id: r.target_id,
      title: r.title,
      year: r.year,
      poster_path: r.poster_path,
      original_language: r.original_language,
      preferred_language: r.preferred_language || "original"
    }
  end

  defp movie_attrs_from(attrs) do
    %{
      tmdb_id: attrs.target_id,
      title: attrs[:title],
      year: attrs[:year],
      poster_path: attrs[:poster_path],
      original_language: attrs[:original_language],
      preferred_language: attrs[:preferred_language] || "original"
    }
  end

  defp tap_ok({:ok, value} = res, fun) do
    fun.(value)
    res
  end

  defp tap_ok(other, _fun), do: other
end
