defmodule Cinder.Catalog.ReleaseVerification do
  @moduledoc """
  Release verification holds, mapping-hold retries, and confirmed-release rejection for TV grabs —
  the post-download/pre-import safety net `Cinder.Library.PolicyVerifier` writes into. The movie
  half lives in `Cinder.Catalog.MovieLifecycle` (`record_failure/2` holds, `retry/1`, `cancel/2`
  and `abort_upgrade/2` release, `reject/2` rejects).
  """

  import Ecto.Query

  alias Cinder.Audit
  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, BlockedRelease, Episode, Grab, Season}
  alias Cinder.Download
  alias Cinder.Notifier
  alias Cinder.Repo

  @doc false
  def hold_grab_verification(%Grab{} = grab) do
    observed_attempts = grab.download_attempts || 0

    case Repo.update_all(
           from(g in Grab,
             where:
               g.id == ^grab.id and g.mapping_status == :resolved and
                 g.download_attempts == ^observed_attempts and not is_nil(g.content_path),
             select: g
           ),
           set: [
             mapping_status: :verification_blocked,
             download_attempts: observed_attempts + 1,
             updated_at: Catalog.now()
           ]
         ) do
      {1, [held]} ->
        # Guarded on `mapping_status == :resolved`, so this fires once per hold (resolved →
        # verification_blocked), never on a re-observation of an already-held grab.
        Notifier.notify({:operator_hold, held, :verification_blocked})
        broadcast_grab_and_ok(held)

      {0, _} ->
        {:error, :stale_grab}
    end
  end

  # The operator actions below refuse a grab that does not offer them (`Attention.offers?/2`), then
  # claim the hold the classification read with a compare-and-swap on `mapping_status`.

  @doc false
  def retry_grab_verification(%Grab{} = grab),
    do: retry_grab(grab, :retry_verification, :verification_blocked, :verification_not_held)

  @doc false
  def retry_grab_mapping(%Grab{} = grab),
    do: retry_grab(grab, :retry_mapping, :needs_mapping, :mapping_not_held)

  defp retry_grab(grab, action, from_status, error_atom) do
    if Attention.offers?(grab, action),
      do: claim_retry(grab, from_status, error_atom),
      else: {:error, error_atom}
  end

  defp claim_retry(grab, from_status, error_atom) do
    case Repo.update_all(
           from(g in Grab,
             where: g.id == ^grab.id and g.mapping_status == ^from_status,
             select: g
           ),
           set: [mapping_status: :resolved, download_attempts: 0, updated_at: Catalog.now()]
         ) do
      {1, [retried]} -> broadcast_grab_and_ok(retried)
      {0, _} -> {:error, error_atom}
    end
  end

  @doc false
  # The operator's "Import anyway" on a TV verification hold (GitHub #630): releases the hold like
  # `retry_grab_verification/1`, but also flags THIS grab row `verification_waived`, so its next
  # import skips the checks whose outcome was unknown (`PolicyVerifier`'s `:waive_unavailable`; a
  # decidable mismatch still rejects). The claim is guarded on the live hold, so a grab the poller
  # or a concurrent Retry already released is `:verification_not_held`; the audit row commits with
  # the flip or not at all, and the one broadcast follows the commit.
  def import_grab_anyway(%Grab{} = grab, actor) do
    if Attention.offers?(grab, :import_anyway),
      do: waive_verification(grab, actor),
      else: {:error, :verification_not_held}
  end

  defp waive_verification(grab, actor) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(
               from(g in Grab,
                 where: g.id == ^grab.id and g.mapping_status == :verification_blocked,
                 select: g
               ),
               set: [
                 mapping_status: :resolved,
                 verification_waived: true,
                 download_attempts: 0,
                 updated_at: Catalog.now()
               ]
             ) do
          {1, [released]} ->
            Audit.log_or_rollback(actor, :import_grab_anyway, released, %{
              release_title: released.release_title,
              from: :verification_blocked
            })

            released

          {0, _} ->
            Repo.rollback(:verification_not_held)
        end
      end)

    with {:ok, released} <- result, do: broadcast_grab_and_ok(released)
  end

  @doc false
  # Called by `Catalog.Grabs.cancel_grab/1` inside its transaction, after the cancel claim, before
  # the delete unlinks the episodes. Reads the live row rather than the caller's struct, so a grab
  # the poller or a Retry just resolved is never blocklisted. Non-raising (`block_grab_release/2`).
  def block_cancelled_hold(%Grab{id: id}) do
    case Repo.one(
           from g in Grab, where: g.id == ^id and g.mapping_status == :verification_blocked
         ) do
      nil -> :ok
      held -> Catalog.block_grab_release(held, :verification_cancelled)
    end
  end

  defp broadcast_grab_and_ok(grab) do
    Catalog.broadcast_series(Catalog.series_id_for_grab(grab.id))
    {:ok, grab}
  end

  @doc false
  def reject_grab_release(%Grab{} = expected, evidence) do
    expected_episode_ids = expected_grab_episode_ids(expected)

    result =
      Repo.transaction(fn ->
        {claimed, _} =
          Repo.update_all(
            reject_grab_query(expected),
            set: [updated_at: Catalog.now()]
          )

        if claimed != 1, do: Repo.rollback(:stale_release)
        fresh = Repo.get!(Grab, expected.id)
        episode_ids = Catalog.episode_ids_for_grab(fresh.id) |> Enum.sort()
        series_ids = series_ids_for_episode_ids(episode_ids)

        if stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
          do: Repo.rollback(:stale_release)

        [series_id] = series_ids

        insert_blocked_release!(%{
          series_id: series_id,
          release_title: fresh.release_title,
          reason: policy_reason(evidence)
        })

        intent_ids =
          Download.fence_episode_cleanup(episode_ids, [
            Catalog.grab_cleanup_spec(fresh, episode_ids)
          ])

        deleted = Repo.delete!(fresh)
        {deleted, intent_ids, series_id}
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      Catalog.broadcast_series(series_id)
      {:ok, deleted}
    end
  end

  defp reject_grab_query(expected) do
    from g in Grab,
      where:
        g.id == ^expected.id and g.mapping_status == :resolved and
          g.release_title == ^expected.release_title and
          g.release_policy_snapshot == ^expected.release_policy_snapshot
  end

  defp stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
    do: episode_ids == [] or episode_ids != expected_episode_ids or length(series_ids) != 1

  defp series_ids_for_episode_ids(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  defp expected_grab_episode_ids(%Grab{episodes: episodes}) when is_list(episodes),
    do: episodes |> Enum.map(& &1.id) |> Enum.sort()

  defp expected_grab_episode_ids(%Grab{
         mapping_snapshot: %{"reserved_episode_ids" => episode_ids}
       })
       when is_list(episode_ids),
       do: Enum.sort(episode_ids)

  defp expected_grab_episode_ids(%Grab{}), do: :unknown

  defp policy_reason(evidence), do: inspect({:release_policy_mismatch, evidence})

  defp insert_blocked_release!(attrs) do
    %BlockedRelease{}
    |> BlockedRelease.changeset(attrs)
    |> Repo.insert!()
  end
end
