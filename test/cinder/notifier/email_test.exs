defmodule Cinder.Notifier.EmailTest do
  # async: false — mutates Cinder.Mailer's Application env to simulate SMTP-configured.
  use Cinder.DataCase, async: false

  import Swoosh.TestAssertions
  import Cinder.AccountsFixtures

  alias Cinder.Notifier.Email
  alias Cinder.Requests.Request

  setup do
    original = Application.get_env(:cinder, Cinder.Mailer, [])
    on_exit(fn -> Application.put_env(:cinder, Cinder.Mailer, original) end)
    :ok
  end

  # The "configured" guard is config-shaped (a saved smtp_host), not adapter-shaped — the
  # adapter stays Swoosh.Adapters.Test in every test regardless, so this is the only way to
  # flip the guard while still capturing delivered emails.
  defp configure_smtp! do
    current = Application.get_env(:cinder, Cinder.Mailer, [])
    Application.put_env(:cinder, Cinder.Mailer, Keyword.put(current, :relay, "smtp.test"))
  end

  defp confirmed_user(attrs \\ %{}) do
    user = user_fixture()
    user |> Ecto.Changeset.change(Map.new(attrs)) |> Repo.update!()
  end

  defp insert_approved_request!(user, target_type, target_id, opts \\ []) do
    attrs =
      Map.merge(
        %{
          user_id: user.id,
          target_type: target_type,
          target_id: target_id,
          status: :approved,
          title: "T"
        },
        Map.new(opts)
      )

    %Request{} |> Request.create_changeset(attrs) |> Repo.insert!()
  end

  describe "SMTP unconfigured" do
    test "skips silently, no attempt to email" do
      user = confirmed_user()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      refute_email_sent()
    end
  end

  describe "request_approved" do
    test "emails the requester" do
      configure_smtp!()
      user = confirmed_user()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      assert_email_sent(to: user.email, subject: "Your request for Arrival (2016) was approved")
    end

    test "an approved book names its format and promises monitoring, not a download" do
      configure_smtp!()
      user = confirmed_user()

      request = %{
        title: "Dune",
        year: 1965,
        target_type: "book",
        season_number: nil,
        media_kind: :ebook,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})

      assert_email_sent(fn email ->
        assert email.subject == "Your request for Dune (1965) (eBook) was approved"
        # Book acquisition does not exist until B4; approval only starts monitoring.
        refute email.text_body =~ "downloading"
        assert email.text_body =~ "watch for a copy"
      end)
    end

    # The third literally-enumerating surface, fenced through its public seam because
    # `request_title/1` is private. `Cinder.Requests.BookRequestTest` fences the other two.
    # A book kind added to the registry without a clause here silently drops the format from
    # every approval and denial email.
    test "every book kind gets its own approval subject" do
      configure_smtp!()

      subjects =
        Enum.map(Cinder.LibraryKind.books(), fn kind ->
          user = confirmed_user()

          request = %{
            title: "Dune",
            year: 1965,
            target_type: "book",
            season_number: nil,
            media_kind: kind,
            user_id: user.id,
            approved_by_id: nil,
            user: user
          }

          assert :ok = Email.notify({:request_approved, request})

          subject =
            receive do
              {:email, email} -> email.subject
            after
              200 -> flunk("no approval email for #{kind}")
            end

          refute subject == "Your request for Dune (1965) was approved",
                 "the #{kind} approval subject drops the format"

          subject
        end)

      assert Enum.uniq(subjects) == subjects
    end

    test "skips the requester's own auto-approval as redundant" do
      configure_smtp!()
      admin = confirmed_user(role: :admin)

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: admin.id,
        approved_by_id: admin.id,
        user: admin
      }

      assert :ok = Email.notify({:request_approved, request})
      refute_email_sent()
    end

    test "still emails when a DIFFERENT admin approved it" do
      configure_smtp!()
      user = confirmed_user()
      admin = confirmed_user(role: :admin)

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: admin.id,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      assert_email_sent(to: user.email)
    end

    test "skips when the requester opted out (notify_email: false)" do
      configure_smtp!()
      user = confirmed_user(notify_email: false)

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      refute_email_sent()
    end

    test "skips an unconfirmed address" do
      configure_smtp!()
      user = confirmed_user(confirmed_at: nil)

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      refute_email_sent()
    end

    test "names the season for a season request, not just the series" do
      configure_smtp!()
      user = confirmed_user()

      request = %{
        title: "Severance",
        year: 2022,
        target_type: "season",
        season_number: 2,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_approved, request})
      assert_email_sent(subject: ~r/Severance \(2022\) Season 2/)
    end

    test "composes in the recipient's stored locale, not the caller's" do
      configure_smtp!()
      user = confirmed_user(locale: "fr")

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      Gettext.put_locale(CinderWeb.Gettext, "en")
      on_exit(fn -> Gettext.put_locale(CinderWeb.Gettext, "en") end)

      assert :ok = Email.notify({:request_approved, request})
      assert_email_sent(subject: "Votre demande pour Arrival (2016) a été approuvée")

      # The calling process' own locale is untouched afterward.
      assert Gettext.get_locale(CinderWeb.Gettext) == "en"
    end

    test "a malformed event with no loaded :user degrades to a no-op, never raises" do
      configure_smtp!()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: 1,
        approved_by_id: nil,
        user: %Ecto.Association.NotLoaded{}
      }

      assert :ok = Email.notify({:request_approved, request})
      refute_email_sent()
    end
  end

  describe "request_denied" do
    test "emails the requester the reason in their locale" do
      configure_smtp!()
      user = confirmed_user()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_denied, request, "not for the household"})

      assert_email_sent(
        to: user.email,
        subject: "Your request for Arrival (2016) was declined",
        text_body: ~r/not for the household/
      )
    end

    test "omits the reason line when no reason was given" do
      configure_smtp!()
      user = confirmed_user()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_denied, request, ""})

      assert_receive {:email, email}
      assert email.subject == "Your request for Arrival (2016) was declined"
      refute email.text_body =~ "Reason:"
    end

    test "skips silently when SMTP is unconfigured" do
      user = confirmed_user()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        approved_by_id: nil,
        user: user
      }

      assert :ok = Email.notify({:request_denied, request, "no"})
      refute_email_sent()
    end

    test "a malformed event with no loaded :user degrades to a no-op, never raises" do
      configure_smtp!()

      request = %{
        title: "Arrival",
        year: 2016,
        target_type: "movie",
        season_number: nil,
        user_id: 1,
        approved_by_id: nil,
        user: %Ecto.Association.NotLoaded{}
      }

      assert :ok = Email.notify({:request_denied, request, "no"})
      refute_email_sent()
    end
  end

  describe "movie_available / movie_failed" do
    test "emails every approved requester for that movie, including an admin" do
      configure_smtp!()
      alice = confirmed_user()
      admin = confirmed_user(role: :admin)
      insert_approved_request!(alice, "movie", 603)
      insert_approved_request!(admin, "movie", 603)

      movie = %{tmdb_id: 603, title: "The Matrix", year: 1999}
      assert :ok = Email.notify({:movie_available, movie})

      assert_email_sent(to: alice.email, subject: "The Matrix (1999) is ready to watch")
      assert_email_sent(to: admin.email, subject: "The Matrix (1999) is ready to watch")
    end

    test "does not email a still-pending or denied requester" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "movie", 604, status: :denied)

      assert :ok = Email.notify({:movie_available, %{tmdb_id: 604, title: "Dune", year: 2021}})
      refute_email_sent()
    end

    test "movie_failed reports the reason and reaches the requester" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "movie", 605)

      movie = %{tmdb_id: 605, title: "Dune", year: 2021}
      assert :ok = Email.notify({:movie_failed, movie, :no_match})

      assert_email_sent(
        to: user.email,
        subject: "We couldn't get Dune (2021)",
        text_body: ~r/no_match/
      )
    end

    test "no requesters means no email, no error" do
      configure_smtp!()
      assert :ok = Email.notify({:movie_available, %{tmdb_id: 999_999, title: "X", year: 2020}})
      refute_email_sent()
    end
  end

  describe "season_available" do
    test "emails the requester of that specific season" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "season", 1399, season_number: 2)

      season = %{tmdb_id: 1399, title: "GoT", season_number: 2, poster_path: nil}
      assert :ok = Email.notify({:season_available, season})

      assert_email_sent(to: user.email, subject: "GoT Season 2 is ready to watch")
    end

    test "does not notify a requester of a different season" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "season", 1399, season_number: 1)

      season = %{tmdb_id: 1399, title: "GoT", season_number: 2, poster_path: nil}
      assert :ok = Email.notify({:season_available, season})
      refute_email_sent()
    end
  end

  describe "book_available" do
    test "emails every approved requester of that work and media kind" do
      configure_smtp!()
      alice = confirmed_user()
      bob = confirmed_user()
      insert_approved_request!(alice, "book", 77, media_kind: :ebook)
      insert_approved_request!(bob, "book", 77, media_kind: :ebook)

      target = %{work_id: 77, media_kind: :ebook, work: %{title: "The Dispossessed"}}
      assert :ok = Email.notify({:book_available, target})

      assert_email_sent(to: alice.email, subject: "The Dispossessed is ready to read")
      assert_email_sent(to: bob.email, subject: "The Dispossessed is ready to read")
    end

    test "does not notify the requester of the other media kind of the same work" do
      # One work carries an :ebook and an :audiobook target independently. Telling the audiobook
      # requester their book is ready because the e-book landed is a lie about a different file.
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "book", 78, media_kind: :audiobook)

      target = %{work_id: 78, media_kind: :ebook, work: %{title: "The Dispossessed"}}
      assert :ok = Email.notify({:book_available, target})

      refute_email_sent()
    end

    test "a work deleted between the import and the notification degrades to a no-op" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "book", 79, media_kind: :ebook)

      target = %{id: 4, work_id: 79, media_kind: :ebook, work: nil}
      assert :ok = Email.notify({:book_available, target})

      assert_email_sent(to: user.email, subject: "book target #4 is ready to read")
    end
  end

  describe "book_target_held" do
    test "emails every approved requester of that work and media kind" do
      configure_smtp!()
      alice = confirmed_user()
      insert_approved_request!(alice, "book", 80, media_kind: :ebook)

      target = %{
        work_id: 80,
        media_kind: :ebook,
        work: %{title: "The Dispossessed"},
        hold_reason: "download_failed"
      }

      assert :ok = Email.notify({:book_target_held, target})

      assert_email_sent(to: alice.email, subject: "We couldn't get The Dispossessed")
    end

    test "does not notify the requester of the other media kind of the same work" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "book", 81, media_kind: :audiobook)

      target = %{
        work_id: 81,
        media_kind: :ebook,
        work: %{title: "The Dispossessed"},
        hold_reason: "download_failed"
      }

      assert :ok = Email.notify({:book_target_held, target})

      refute_email_sent()
    end
  end

  describe "episodes_search_exhausted" do
    test "emails the season's requester" do
      configure_smtp!()
      user = confirmed_user()
      insert_approved_request!(user, "season", 1399, season_number: 1)

      episodes = [
        %{
          episode_number: 3,
          season: %{season_number: 1, series: %{tmdb_id: 1399, title: "GoT"}}
        }
      ]

      assert :ok = Email.notify({:episodes_search_exhausted, episodes})
      assert_email_sent(to: user.email, subject: "We couldn't find GoT Season 1")
    end
  end

  describe "account_activated" do
    test "emails the activated user" do
      configure_smtp!()
      user = confirmed_user()

      assert :ok = Email.notify({:account_activated, user})
      assert_email_sent(to: user.email, subject: "Your Cinder account is now active")
    end

    test "skips a user who opted out (notify_email: false)" do
      configure_smtp!()
      user = confirmed_user(notify_email: false)

      assert :ok = Email.notify({:account_activated, user})
      refute_email_sent()
    end

    test "skips an unconfirmed address" do
      configure_smtp!()
      user = confirmed_user(confirmed_at: nil)

      assert :ok = Email.notify({:account_activated, user})
      refute_email_sent()
    end

    test "skips silently when SMTP is unconfigured" do
      user = confirmed_user()

      assert :ok = Email.notify({:account_activated, user})
      refute_email_sent()
    end
  end

  describe "issue_resolved" do
    defp issue_report(user, overrides \\ %{}) do
      Map.merge(
        %{title: "Dune", target_type: "movie", season_number: nil, user_id: user.id, user: user},
        Map.new(overrides)
      )
    end

    test "emails the reporter when their issue is resolved" do
      configure_smtp!()
      user = confirmed_user()

      assert :ok = Email.notify({:issue_resolved, issue_report(user)})

      assert_email_sent(
        to: user.email,
        subject: "The issue you reported for Dune is resolved"
      )
    end

    test "names the season for a season report" do
      configure_smtp!()
      user = confirmed_user()

      assert :ok =
               Email.notify(
                 {:issue_resolved, issue_report(user, %{target_type: "season", season_number: 2})}
               )

      assert_email_sent(
        to: user.email,
        subject: "The issue you reported for Dune Season 2 is resolved"
      )
    end

    test "skips a reporter who opted out" do
      configure_smtp!()
      user = confirmed_user(notify_email: false)

      assert :ok = Email.notify({:issue_resolved, issue_report(user)})
      refute_email_sent()
    end

    test "skips silently when SMTP is unconfigured" do
      user = confirmed_user()

      assert :ok = Email.notify({:issue_resolved, issue_report(user)})
      refute_email_sent()
    end
  end

  describe "unrecognized events" do
    test "are ignored" do
      configure_smtp!()
      assert :ok = Email.notify({:maintenance_completed, :scan_movies})
      refute_email_sent()
    end

    test "issue_reported and issue_dismissed do not email the reporter" do
      configure_smtp!()
      user = confirmed_user()

      report = %{
        title: "Dune",
        target_type: "movie",
        season_number: nil,
        user_id: user.id,
        user: user
      }

      assert :ok = Email.notify({:issue_reported, report})
      assert :ok = Email.notify({:issue_dismissed, report})
      refute_email_sent()
    end
  end
end
