defmodule Cinder.Notifier.Log do
  @moduledoc "Default notifier: logs each event. Approvals/failures aren't silent in the logs."
  @behaviour Cinder.Notifier
  require Logger

  @impl true
  def notify({:request_approved, request}),
    do: log("request approved: #{request.title} (user ##{request.user_id})")

  def notify({:movie_available, movie}), do: log("movie available: #{movie.title}")

  def notify({:movie_failed, movie, reason}),
    do: log("movie failed: #{movie.title} (#{inspect(reason)})")

  def notify(other), do: log("event: #{inspect(other)}")

  defp log(msg), do: Logger.info("[notifier] " <> msg)
end
