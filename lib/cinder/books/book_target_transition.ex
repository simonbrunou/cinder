defmodule Cinder.Books.BookTargetTransition do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Repo

  def guarded(%BookTarget{} = target, attrs, expected) do
    case BookTarget.transition_changeset(target, attrs) do
      %{valid?: true} = changeset ->
        target.id
        |> guarded_update(changeset.changes, expected)
        |> publish()

      %{valid?: false} = changeset ->
        {:error, changeset}
    end
  end

  defp guarded_update(id, changes, expected) do
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

  defp publish({:ok, target}) do
    Books.broadcast({:book_target_updated, target})
    {:ok, target}
  end

  defp publish({:error, reason}), do: {:error, reason}
end
