defmodule Cinder.Notifier.Email do
  @moduledoc """
  Per-requester email transport: emails the user(s) who requested a title when their
  request is approved, or their movie/season becomes available or fails. This is the
  "request it, get told when it's ready" half of the Seerr promise — Discord/Log only
  reach a household-wide channel, not the individual who asked.

  Skips silently (never raises) when SMTP isn't configured (`configured?/0` checks for a
  saved `smtp_host`, not the resolved adapter — the adapter is `Swoosh.Adapters.Test` in
  every test regardless, so the guard has to be config-shaped, not adapter-shaped, to stay
  testable), when the user opted out (`notify_email: false`), or when the address isn't
  confirmed. `Cinder.Notifier.notify/1` catches on top of this too, matching Log/Discord.

  Deliberate exception to "the domain stays gettext-free" (`CinderWeb.SettingsLabels`):
  composing the email body IS the only render step there is for it, so this module calls
  gettext directly — always in the RECIPIENT's stored `locale`
  (`Gettext.with_locale/3`, scoped to just the composition), never the calling process'
  locale. A poller tick or an admin's own `/requests` session must not leak into the
  message a requester reads, and must not leave its own locale changed afterward either.
  """
  @behaviour Cinder.Notifier

  use Gettext, backend: CinderWeb.Gettext

  import Swoosh.Email

  alias Cinder.Accounts.User
  alias Cinder.Mailer
  alias Cinder.Requests

  require Logger

  @impl true
  def notify({:request_approved, request}), do: notify_request_approved(request)
  def notify({:movie_available, movie}), do: notify_movie(movie, :available)
  def notify({:movie_failed, movie, reason}), do: notify_movie(movie, {:failed, reason})
  def notify({:season_available, season}), do: notify_season(season)
  def notify({:episodes_search_exhausted, episodes}), do: notify_episodes_exhausted(episodes)
  def notify(_other), do: :ok

  # The requester's own instant auto-approve (they're an admin, or auto_approve_all applies
  # to their own submit) is redundant — no one else made a decision for them to be told
  # about. Every other approval (a different admin, or a non-admin under auto_approve_all)
  # still emails: they submitted and walked away.
  defp notify_request_approved(%{approved_by_id: id, user_id: id}) when not is_nil(id), do: :ok

  defp notify_request_approved(%{user: %User{} = user} = request) do
    send_to(user, fn ->
      title = request_title(request)

      {gettext("Your request for %{title} was approved", title: title),
       gettext(
         "Good news — your request for %{title} was approved and will start downloading soon.",
         title: title
       )}
    end)
  end

  # %Ecto.Association.NotLoaded{} (a malformed caller) degrades to a no-op, not a raise —
  # matching Discord's own defensive fallback for the same field.
  defp notify_request_approved(_request), do: :ok

  defp notify_movie(movie, :available) do
    each_requester(Requests.approved_requesters_for_movie(movie.tmdb_id), fn ->
      title = title_year(movie)

      {gettext("%{title} is ready to watch", title: title),
       gettext("Your request for %{title} is ready to watch.", title: title)}
    end)
  end

  defp notify_movie(movie, {:failed, reason}) do
    each_requester(Requests.approved_requesters_for_movie(movie.tmdb_id), fn ->
      title = title_year(movie)

      {gettext("We couldn't get %{title}", title: title),
       gettext(
         "We're sorry — your request for %{title} could not be completed (%{reason}) and has " <>
           "been parked. An admin may need to take a look.",
         title: title,
         reason: inspect(reason)
       )}
    end)
  end

  defp notify_season(%{tmdb_id: tmdb_id, season_number: season_number} = season) do
    each_requester(Requests.approved_requesters_for_season(tmdb_id, season_number), fn ->
      title = season_title(season)

      {gettext("%{title} is ready to watch", title: title),
       gettext("Your requested season is ready to watch: %{title}.", title: title)}
    end)
  end

  defp notify_episodes_exhausted([%{season: %{series: series, season_number: number}} | _]) do
    each_requester(Requests.approved_requesters_for_season(series.tmdb_id, number), fn ->
      title = gettext("%{title} Season %{season}", title: series.title, season: number)

      {gettext("We couldn't find %{title}", title: title),
       gettext(
         "We're sorry — we couldn't find a release for %{title} after several attempts. " <>
           "An admin may need to take a look.",
         title: title
       )}
    end)
  end

  defp notify_episodes_exhausted(_episodes), do: :ok

  defp each_requester(users, compose), do: Enum.each(users, &send_to(&1, compose))

  defp send_to(%User{} = user, compose) do
    if configured?() and eligible?(user) do
      locale = user.locale || Cinder.Locales.canonical()
      {subject, body} = Gettext.with_locale(CinderWeb.Gettext, locale, compose)
      deliver(user.email, subject, body)
    end

    :ok
  end

  defp deliver(to, subject, body) do
    email =
      new()
      |> to(to)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.warning("email notify delivery failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("email notify raised: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("email notify #{kind}: #{inspect(value)}")
      :ok
  end

  defp configured? do
    case Application.get_env(:cinder, Cinder.Mailer, [])[:relay] do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp eligible?(%User{notify_email: true, confirmed_at: confirmed_at, email: email}),
    do: not is_nil(confirmed_at) and is_binary(email) and email != ""

  defp eligible?(_user), do: false

  defp title_year(%{title: title, year: year}) when not is_nil(year), do: "#{title} (#{year})"
  defp title_year(%{title: title}), do: title

  defp season_title(%{title: title, season_number: number}),
    do: gettext("%{title} Season %{season}", title: title, season: number)

  # A season request's own :title column holds only the series name (mirrors Discord's
  # request_line/1), so rendering it bare would read "Frieren was approved" for a request
  # that was actually for one season.
  defp request_title(%{target_type: "season", season_number: number} = request)
       when not is_nil(number),
       do: gettext("%{title} Season %{season}", title: title_year(request), season: number)

  defp request_title(request), do: title_year(request)
end
