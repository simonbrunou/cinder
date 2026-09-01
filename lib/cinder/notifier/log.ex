defmodule Cinder.Notifier.Log do
  @moduledoc "Default notifier: logs each event. Approvals/failures aren't silent in the logs."
  @behaviour Cinder.Notifier

  alias Cinder.Catalog.Episode
  alias Cinder.LibraryKind
  require Logger

  @impl true
  def notify({:request_approved, request}),
    do: log("request approved: #{subject(request)} (user ##{request.user_id})")

  def notify({:request_created, request}),
    do: log("request pending approval: #{subject(request)} (user ##{request.user_id})")

  # Ids + title only (title is TMDB metadata, not PII). The admin's free-text denial reason is
  # deliberately NOT logged — it can carry anything an admin typed.
  def notify({:request_denied, request, _reason}),
    do: log("request denied: #{subject(request)} (user ##{request.user_id})")

  def notify({:user_registered, %{id: id}}) when is_integer(id),
    do: log("user_registered user ##{id}")

  def notify({:user_registered, _user}), do: log("user_registered")

  def notify({:account_activated, %{id: id}}) when is_integer(id),
    do: log("account activated: user ##{id}")

  def notify({:account_activated, _user}), do: log("account activated")

  # Ids + title + category only — the free-text `detail` is user input and never logged (no PII).
  def notify({:issue_reported, report}),
    do: log("issue reported: #{report.title} (#{report.category}, user ##{report.user_id})")

  def notify({:issue_resolved, report}),
    do: log("issue resolved: #{report.title} (user ##{report.user_id})")

  def notify({:issue_dismissed, report}),
    do: log("issue dismissed: #{report.title} (user ##{report.user_id})")

  def notify({:movie_available, movie}), do: log("movie available: #{movie.title}")

  def notify({:book_available, target}),
    do: log("book available: #{book_title(target)} (#{target.media_kind})")

  def notify({:book_target_held, target}),
    do: log("book target held: #{book_title(target)} (#{target.hold_reason})")

  def notify({:movie_failed, movie, reason}),
    do: log("movie failed: #{movie.title} (#{inspect(reason)})")

  def notify({:season_available, season}),
    do: log("season available: #{season.title} season #{season.season_number}")

  def notify({:grab_failed, grab, reason}),
    do: log("tv grab failed: ##{grab.id} (#{inspect(reason)})")

  # A newly created operator-action hold on a TV grab (mapping / verification / residual files):
  # the download is waiting for a human on /activity. Logged so holds aren't silent.
  def notify({:operator_hold, %{id: id}, reason}),
    do: log("operator hold: tv grab ##{id} (#{reason})")

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

  # A request's own :title column holds only the work/series name, so two rows that differ only
  # in season or book format would log identically.
  defp subject(%{target_type: "book", media_kind: kind} = request) when not is_nil(kind),
    do: "#{request.title} (#{LibraryKind.format_label(kind)})"

  defp subject(%{target_type: "season", season_number: number} = request)
       when not is_nil(number),
       do: "#{request.title} (season #{number})"

  defp subject(request), do: request.title

  # The target's own work title, defensively: the poller reloads the target before notifying, but
  # a work deleted in that window would otherwise raise inside a notification.
  defp book_title(%{work: %{title: title}}) when is_binary(title), do: title
  defp book_title(%{id: id}), do: "book target ##{id}"

  defp log(msg), do: Logger.info("[notifier] " <> msg)
end
