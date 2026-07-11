defmodule Cinder.Notifier.Log do
  @moduledoc "Default notifier: logs each event. Approvals/failures aren't silent in the logs."
  @behaviour Cinder.Notifier

  alias Cinder.Catalog.Episode
  require Logger

  @impl true
  def notify({:request_approved, request}),
    do: log("request approved: #{request.title} (user ##{request.user_id})")

  def notify({:movie_available, movie}), do: log("movie available: #{movie.title}")

  def notify({:movie_failed, movie, reason}),
    do: log("movie failed: #{movie.title} (#{inspect(reason)})")

  def notify({:season_available, season}),
    do: log("season available: #{season.title} season #{season.season_number}")

  def notify({:grab_failed, grab, reason}),
    do: log("tv grab failed: ##{grab.id} (#{inspect(reason)})")

  def notify({:episodes_search_exhausted, episodes}),
    do: log("episode search exhausted: #{episodes_summary(episodes)}")

  def notify({:maintenance_completed, key}),
    do: log("maintenance completed: #{key}")

  def notify({:maintenance_failed, key, reason}),
    do: log("maintenance failed: #{key} (#{inspect(reason)})")

  def notify(other), do: log("event: #{inspect(other)}")

  defp episodes_summary([%{season: %{series: series}} | _] = episodes) do
    codes =
      Enum.map_join(episodes, ", ", fn ep ->
        Episode.code(ep.season.season_number, ep.episode_number)
      end)

    "#{series.title} (#{codes})"
  end

  defp episodes_summary(episodes), do: "#{length(episodes)} episode(s)"

  defp log(msg), do: Logger.info("[notifier] " <> msg)
end
