defmodule CinderWeb.RequestHelpersTest do
  use ExUnit.Case, async: true

  alias CinderWeb.RequestHelpers

  # `/requests` and the dashboard approval queue both flash this message for a failed approval
  # (#810), so each `Requests.approve_request/3` refusal and a task exit get one row here.
  @generic "Couldn't approve that request. Please try again."

  for {result, message} <- [
        {{:ok, {:error, :not_pending}}, "That request was already decided."},
        {{:ok, {:error, :target_held}},
         "That title is on hold. Clear the hold before approving it."},
        {{:ok, {:error, :approver_deleted}},
         "Your admin account was deleted. Sign in again to approve requests."},
        {{:ok, {:error, :unsupported_target}}, "This kind of request isn't supported yet."},
        {{:ok, {:error, :invalid_media_profile}}, @generic},
        {{:ok, {:error, :timeout}}, @generic},
        {{:ok, {:error, %Ecto.Changeset{}}}, @generic},
        {{:exit, :killed}, @generic}
      ] do
    test "approval_error_message/1 for #{inspect(result)}" do
      assert RequestHelpers.approval_error_message(unquote(Macro.escape(result))) ==
               unquote(message)
    end
  end
end
