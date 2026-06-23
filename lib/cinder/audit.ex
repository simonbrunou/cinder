defmodule Cinder.Audit do
  @moduledoc """
  Admin audit trail. `log/4` records one destructive admin action.

  **The write happens inside the caller's `Repo.transaction`** — call it after the
  guard passes and before commit, so a rolled-back op (e.g. a last-admin delete)
  leaves no orphan audit row. `log/4` itself opens no transaction.
  """
  alias Cinder.Accounts.User
  alias Cinder.Audit.AdminAudit
  alias Cinder.Repo

  @doc """
  Records `action` (atom or string) taken by `actor` (`%User{}` or nil) against
  `entity` (a persisted struct, or a `{type_string, id}` tuple), with a free-form
  `detail` map. Returns `{:ok, %AdminAudit{}}` or `{:error, changeset}`.
  """
  def log(actor, action, entity, detail \\ %{}) do
    {entity_type, entity_id} = entity_ref(entity)

    %AdminAudit{}
    |> AdminAudit.changeset(%{
      actor_id: actor_id(actor),
      action: to_string(action),
      entity_type: entity_type,
      entity_id: entity_id,
      detail: detail
    })
    |> Repo.insert()
  end

  defp actor_id(%User{id: id}), do: id
  defp actor_id(nil), do: nil

  defp entity_ref({type, id}) when is_binary(type), do: {type, id}

  defp entity_ref(%mod{id: id}) do
    {mod |> Module.split() |> List.last(), id}
  end
end
