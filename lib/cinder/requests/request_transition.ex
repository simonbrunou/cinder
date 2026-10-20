defmodule Cinder.Requests.RequestTransition do
  @moduledoc false
  # The `requests` adapter of `Cinder.GuardedWrite`: an admin's decision on a pending request.
  # Only `Cinder.Requests` names it.
  @behaviour Cinder.GuardedWrite

  alias Cinder.Accounts.User
  alias Cinder.Repo
  alias Cinder.Requests.Request

  @impl true
  def changeset(request, attrs), do: Request.status_changeset(request, attrs)

  # The approval's `proposed_profile_id` write can race a re-kind of that profile:
  # `Cinder.Requests` re-reads the profile inside its `:immediate` transaction just before the
  # write, and the `requests_profile_integrity` trigger is the fence behind that. The literal is
  # also spelled out in the migrations that create the trigger and in `Request`'s
  # `check_constraint/3` calls; `test/cinder/guarded_write_test.exs` is what catches a drift.
  #
  # The same write can race deletion of its `approved_by_id` user. SQLite's FK message names no
  # column, so this narrows by checking the approver row is gone. That is a strong hint, not proof
  # of causation: `requests` also FKs `proposed_profile_id`, but the profile trigger fires first
  # for that race. Any other FK failure re-raises.
  @impl true
  def refusal(message, attrs) do
    cond do
      message =~ "requests_profile_integrity" -> :invalid_media_profile
      message == "FOREIGN KEY constraint failed" and approver_gone?(attrs) -> :approver_deleted
      true -> nil
    end
  end

  defp approver_gone?(%{approved_by_id: id}) when not is_nil(id), do: is_nil(Repo.get(User, id))
  defp approver_gone?(_attrs), do: false

  # Approval and denial are announced by `Cinder.Requests` itself after commit: an auto-approval
  # inserts its row rather than flipping one, so no write could announce it.
  @impl true
  def publish(_requests), do: :ok
end
