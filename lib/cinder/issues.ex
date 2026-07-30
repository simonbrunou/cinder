defmodule Cinder.Issues do
  @moduledoc """
  Post-delivery problem reports (Seerr parity): a requester flags something wrong with a title
  that is actually available to them (wrong content, audio, subtitles, playback…), and an admin
  resolves or dismisses it. A separate table from `Cinder.Requests` — the approval gate and the
  request model are untouched.

  Reports are requester-owned and rate-bounded (`@max_open_per_user` open reports). Creation is
  gated on the target being genuinely available (a movie at `:available`, or a fully-available
  season) so a report can only be filed for content the household can actually watch. PubSub +
  post-commit `Cinder.Notifier` events mirror the requests idiom.
  """
  import Ecto.Query
  alias Cinder.Accounts.User
  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Issues.IssueReport
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Util

  @topic "issues"

  # A soft cap so a single requester can't flood the admin queue; a module attr, not a setting.
  @max_open_per_user 5

  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, msg)

  @doc """
  Files a report for `user`. Refuses when the user is already at their open-report cap
  (`{:error, :too_many_open}`) or when the target isn't available to them
  (`{:error, :not_available}`). The target's `title` is snapshotted from the catalog (canonical,
  not client-supplied) so the admin queue renders without a join. Broadcasts and notifies
  post-commit.
  """
  def create_report(%User{} = user, attrs) do
    if open_count(user) >= @max_open_per_user do
      {:error, :too_many_open}
    else
      case available_snapshot(attrs) do
        {:ok, snapshot} -> insert_report(user, attrs, snapshot)
        :error -> {:error, :not_available}
      end
    end
  end

  # Availability doubles as the "is this yours to report" gate: in a single household, an
  # available title is watchable by every member, so availability is exactly access.
  defp available_snapshot(%{target_type: "movie", target_id: id}) when is_integer(id) do
    case Catalog.get_movie_by_tmdb_id(id) do
      %Movie{status: :available, title: title} ->
        {:ok, %{target_type: "movie", target_id: id, season_number: nil, title: title}}

      _ ->
        :error
    end
  end

  defp available_snapshot(%{target_type: "season", target_id: id, season_number: n})
       when is_integer(id) and is_integer(n) do
    with true <- MapSet.member?(Catalog.available_season_keys(id), {id, n}),
         %Series{title: title} <- Catalog.get_series_by_tmdb_id(id) do
      {:ok, %{target_type: "season", target_id: id, season_number: n, title: title}}
    else
      _ -> :error
    end
  end

  defp available_snapshot(_), do: :error

  defp insert_report(user, attrs, snapshot) do
    attrs
    |> Map.take([:category, :detail])
    |> Map.merge(%{
      user_id: user.id,
      target_type: snapshot.target_type,
      target_id: snapshot.target_id,
      season_number: snapshot.season_number,
      title: snapshot.title,
      status: :open
    })
    |> then(&IssueReport.create_changeset(%IssueReport{}, &1))
    |> Repo.insert()
    |> Util.tap_ok(fn report ->
      # `user` is already in scope, so attributing the event needs no preload.
      report = %{report | user: user}
      broadcast({:issue_reported, report})
      Notifier.notify({:issue_reported, report})
    end)
  end

  @doc "Open reports, oldest first, with the requester preloaded — the admin queue."
  def list_open do
    Repo.all(
      from r in IssueReport, where: r.status == :open, order_by: [asc: r.id], preload: [:user]
    )
  end

  @doc "Count of open reports — a light query behind an admin badge."
  def count_open do
    Repo.aggregate(from(r in IssueReport, where: r.status == :open), :count)
  end

  @doc "The caller's OWN reports, newest first — drives the `/my-requests` per-title state."
  def list_for_user(%User{id: id}) do
    Repo.all(from r in IssueReport, where: r.user_id == ^id, order_by: [desc: r.id])
  end

  @doc "Whether `user` already has an open report for a movie target — gates the detail-page action."
  def open_report?(%User{id: uid}, "movie", target_id) do
    Repo.exists?(
      from r in IssueReport,
        where:
          r.user_id == ^uid and r.status == :open and
            r.target_type == "movie" and r.target_id == ^target_id
    )
  end

  @doc """
  The caller's OWN reports, projected to JSON-ready maps for a GDPR Art.15/20 data export.
  Own data only — scoped by user id, like `list_for_user/1`.
  """
  def export_for_user(%User{} = user) do
    user
    |> list_for_user()
    |> Enum.map(fn r ->
      %{
        target_type: r.target_type,
        target_id: r.target_id,
        season_number: r.season_number,
        title: r.title,
        category: r.category,
        detail: r.detail,
        status: r.status,
        inserted_at: iso(r.inserted_at),
        updated_at: iso(r.updated_at)
      }
    end)
  end

  @doc "Admin: marks an open report resolved and emails the reporter."
  def resolve(%IssueReport{} = report, %User{} = admin), do: close(report, admin, :resolved)

  @doc "Admin: dismisses an open report (no reporter email — silent close)."
  def dismiss(%IssueReport{} = report, %User{} = admin), do: close(report, admin, :dismissed)

  # Guarded status flip scoped to `status == :open`, so two racing admins can't both notify the
  # reporter (the second update matches 0 rows). One atomic update_all + RETURNING (select: r).
  defp close(%IssueReport{id: id}, %User{id: admin_id}, status) do
    case Repo.update_all(
           from(r in IssueReport, where: r.id == ^id and r.status == :open, select: r),
           set: [status: status, resolver_id: admin_id, updated_at: now()]
         ) do
      {1, [fresh]} ->
        fresh = Repo.preload(fresh, :user)
        broadcast({event_for(status), fresh})
        Notifier.notify({event_for(status), fresh})
        {:ok, fresh}

      {0, _} ->
        {:error, :not_open}
    end
  end

  defp event_for(:resolved), do: :issue_resolved
  defp event_for(:dismissed), do: :issue_dismissed

  defp open_count(%User{id: id}) do
    Repo.aggregate(from(r in IssueReport, where: r.user_id == ^id and r.status == :open), :count)
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
