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

  def notify({:episodes_available, episodes}),
    do: log("episodes available: #{episodes_summary(episodes)}")

  def notify({:grab_failed, grab, reason}),
    do: log("tv grab failed: ##{grab.id} (#{inspect(reason)})")

  def notify({:episodes_search_exhausted, episodes}),
    do: log("episode search exhausted: #{episodes_summary(episodes)}")

  def notify(other), do: log("event: #{inspect(other)}")

  # "Show (S01E02, S01E03)" from a grab's imported episodes (season: :series preloaded), or a
  # bare count if the tree isn't loaded — best-effort, this only feeds a log line.
  defp episodes_summary([%{season: %{series: series}} | _] = episodes) do
    codes =
      Enum.map_join(episodes, ", ", fn ep ->
        "S#{pad(ep.season.season_number)}E#{pad(ep.episode_number)}"
      end)

    "#{series.title} (#{codes})"
  end

  defp episodes_summary(episodes), do: "#{length(episodes)} episode(s)"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp log(msg), do: Logger.info("[notifier] " <> msg)
end
