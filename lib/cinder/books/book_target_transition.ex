defmodule Cinder.Books.BookTargetTransition do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Repo

  def guarded(%BookTarget{} = target, attrs, expected, opts \\ []) do
    case BookTarget.transition_changeset(target, attrs) do
      %{valid?: true} = changeset ->
        target.id
        |> guarded_update(changeset.changes, expected)
        |> publish(Keyword.get(opts, :publish, true))

      %{valid?: false} = changeset ->
        {:error, changeset}
    end
  end

  # `update_all` skips Ecto's `to_constraints`, so `book_targets_profile_integrity` surfaces as a
  # raw Exqlite.Error rather than `{:error, changeset}`. `Books.monitor_target/4` checks the kind
  # up front, but `Books.transition_target/3` is public: rescue on the constraint's own message
  # (not the exception class, which also covers a transient busy) so any caller gets the same
  # explained refusal instead of a raise.
  defp guarded_update(id, changes, expected) do
    do_guarded_update(id, changes, expected)
  rescue
    error in Exqlite.Error ->
      if error.message =~ "book_targets_profile_integrity" do
        {:error, :invalid_media_profile}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp do_guarded_update(id, changes, expected) do
    Repo.transaction(fn ->
      case Repo.update_all(
             from(t in BookTarget,
               where: t.id == ^id and t.status == ^expected,
               select: t
             ),
             set:
               Map.to_list(changes) ++
                 [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
           ) do
        {1, [updated]} -> updated
        {0, _} -> Repo.rollback(:stale_status)
      end
    end)
  end

  # `publish: false` is for a caller inside a transaction — a mid-transaction broadcast would
  # announce a write a rollback can still undo. That caller broadcasts after commit.
  defp publish({:ok, target}, true) do
    Books.broadcast({:book_target_updated, target})
    {:ok, target}
  end

  defp publish(result, _publish?), do: result
end
