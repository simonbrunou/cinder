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
  def notify({:account_activated, user}), do: notify_account_activated(user)
  def notify({:request_approved, request}), do: notify_request_approved(request)
  def notify({:request_denied, request, reason}), do: notify_request_denied(request, reason)
  def notify({:issue_resolved, report}), do: notify_issue_resolved(report)
  def notify({:movie_available, movie}), do: notify_movie(movie, :available)
  def notify({:movie_failed, movie, reason}), do: notify_movie(movie, {:failed, reason})
  def notify({:season_available, season}), do: notify_season(season)
  def notify({:book_available, target}), do: notify_book(target)
  def notify({:book_target_held, target}), do: notify_book_held(target)
  def notify({:episodes_search_exhausted, episodes}), do: notify_episodes_exhausted(episodes)
  def notify(_other), do: :ok

  # A non-admin registers, lands inactive, and waits — this is the one message that tells them an
  # admin let them in. Sent to the activated user themselves (not to requesters), in their locale,
  # and only when they're email-eligible (opted in + confirmed address), via the shared send_to/2.
  defp notify_account_activated(%User{} = user) do
    send_to(user, fn ->
      {gettext("Your Cinder account is now active"),
       gettext(
         "Good news — an admin activated your account. You can now sign in and start requesting."
       )}
    end)
  end

  defp notify_account_activated(_user), do: :ok

  # The requester's own instant auto-approve (they're an admin, or auto_approve_all applies
  # to their own submit) is redundant — no one else made a decision for them to be told
  # about. Every other approval (a different admin, or a non-admin under auto_approve_all)
  # still emails: they submitted and walked away.
  defp notify_request_approved(%{approved_by_id: id, user_id: id}) when not is_nil(id), do: :ok

  defp notify_request_approved(%{user: %User{} = user} = request) do
    send_to(user, fn ->
      title = request_title(request)

      {gettext("Your request for %{title} was approved", title: title),
       approved_body(request, title)}
    end)
  end

  # %Ecto.Association.NotLoaded{} (a malformed caller) degrades to a no-op, not a raise —
  # matching Discord's own defensive fallback for the same field.
  defp notify_request_approved(_request), do: :ok

  # Approving a book only starts monitoring its target — book acquisition does not exist yet
  # (roadmap B4), so promising a download would be a lie.
  defp approved_body(%{target_type: "book"}, title),
    do:
      gettext(
        "Good news — your request for %{title} was approved. Cinder will watch for a copy.",
        title: title
      )

  defp approved_body(_request, title),
    do:
      gettext(
        "Good news — your request for %{title} was approved and will start downloading soon.",
        title: title
      )

  # The requester submitted and walked away; this is the message that tells them an admin
  # declined it — in their locale, with the admin's free-text reason when one was given.
  defp notify_request_denied(%{user: %User{} = user} = request, reason) do
    send_to(user, fn ->
      title = request_title(request)

      {gettext("Your request for %{title} was declined", title: title),
       denied_body(title, reason)}
    end)
  end

  defp notify_request_denied(_request, _reason), do: :ok

  # The reporter filed a problem and walked away; this tells them an admin resolved it — in their
  # locale. Mirrors notify_request_denied/2's defensive %User{}-or-no-op shape.
  defp notify_issue_resolved(%{user: %User{} = user} = report) do
    send_to(user, fn ->
      title = issue_title(report)

      {gettext("The issue you reported for %{title} is resolved", title: title),
       gettext(
         "Good news — the issue you reported for %{title} has been resolved. Please take another look.",
         title: title
       )}
    end)
  end

  defp notify_issue_resolved(_report), do: :ok

  defp denied_body(title, reason) when is_binary(reason) and reason != "" do
    gettext(
      "We're sorry — your request for %{title} was declined. Reason: %{reason}",
      title: title,
      reason: reason
    )
  end

  defp denied_body(title, _reason),
    do: gettext("We're sorry — your request for %{title} was declined.", title: title)

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

  # The books analog of `notify_movie/2`'s `:available` branch. B4b made `:book_available` a real
  # event, and Discord/Log both took it — but those are household-wide channels. Without this the
  # person who actually asked for the book is the one who never hears that it arrived, which is
  # the half of the Seerr promise this transport exists for.
  #
  # Keyed on work AND media kind: one work has an `:ebook` and an `:audiobook` target
  # independently, so the audiobook requester is not served by the e-book landing.
  defp notify_book(%{work_id: work_id, media_kind: media_kind} = target)
       when is_integer(work_id) and is_atom(media_kind) do
    each_requester(Requests.approved_requesters_for_book(work_id, media_kind), fn ->
      title = book_title(target)

      {gettext("%{title} is ready to read", title: title),
       gettext("Your request for %{title} is ready to read.", title: title)}
    end)
  end

  defp notify_book(_target), do: :ok

  # Mirrors `notify_movie/2`'s `{:failed, reason}` branch, reusing its exact copy: "could not be
  # completed" reads fine for a held book too, and reusing the msgid needs no new French string.
  # `target.hold_reason` is already sanitized/bounded (`Books.hold_reason/1`), so it is safe to
  # interpolate directly here (never inspected remote text).
  defp notify_book_held(%{work_id: work_id, media_kind: media_kind} = target)
       when is_integer(work_id) and is_atom(media_kind) do
    each_requester(Requests.approved_requesters_for_book(work_id, media_kind), fn ->
      title = book_title(target)

      {gettext("We couldn't get %{title}", title: title),
       gettext(
         "We're sorry — your request for %{title} could not be completed (%{reason}) and has " <>
           "been parked. An admin may need to take a look.",
         title: title,
         reason: target.hold_reason
       )}
    end)
  end

  defp notify_book_held(_target), do: :ok

  # Defensive, matching Discord's own fallback for the same field: the poller reloads the target
  # before notifying, but a work deleted in that window must not raise inside a transport.
  defp book_title(%{work: %{title: title}}) when is_binary(title), do: title
  defp book_title(%{id: id}), do: gettext("book target #%{id}", id: id)

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

  # Same reason as the season clause: one work can carry both book formats.
  defp request_title(%{target_type: "book", media_kind: :ebook} = request),
    do: gettext("%{title} (eBook)", title: title_year(request))

  defp request_title(%{target_type: "book", media_kind: :audiobook} = request),
    do: gettext("%{title} (audiobook)", title: title_year(request))

  defp request_title(request), do: title_year(request)

  # An issue report snapshots only the title (no year); a season report names its season.
  defp issue_title(%{target_type: "season", season_number: n, title: t}) when not is_nil(n),
    do: gettext("%{title} Season %{season}", title: t, season: n)

  defp issue_title(%{title: t}), do: t
end
