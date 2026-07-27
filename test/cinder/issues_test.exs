defmodule Cinder.IssuesTest do
  use Cinder.DataCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  alias Cinder.Issues
  alias Cinder.Issues.IssueReport

  # An available movie the reporting user can watch (and thus report on).
  defp available_movie(attrs \\ %{}) do
    movie_fixture(Map.merge(%{status: :available}, Map.new(attrs)))
  end

  defp available_season do
    series = series_fixture()
    season = season_fixture(series, season_number: 1)
    _episode = episode_fixture(season, file_path: "/s01e01.mkv", air_date: ~D[2001-01-01])
    {series, season}
  end

  defp report_attrs(movie, overrides \\ %{}) do
    Map.merge(
      %{target_type: "movie", target_id: movie.tmdb_id, category: "audio", detail: "no sound"},
      Map.new(overrides)
    )
  end

  describe "create_report/2 — availability gate" do
    test "creates a report for an available movie, snapshotting the catalog title" do
      user = user_fixture()
      movie = available_movie(%{title: "Dune"})

      assert {:ok, report} = Issues.create_report(user, report_attrs(movie))
      assert report.user_id == user.id
      assert report.target_type == "movie"
      assert report.target_id == movie.tmdb_id
      assert report.category == :audio
      assert report.detail == "no sound"
      assert report.status == :open
      # Title is snapshotted from the catalog, not taken from the caller.
      assert report.title == "Dune"
    end

    test "creates a report for a fully-available season" do
      user = user_fixture()
      {series, _season} = available_season()

      attrs = %{
        target_type: "season",
        target_id: series.tmdb_id,
        season_number: 1,
        category: "subtitles"
      }

      assert {:ok, report} = Issues.create_report(user, attrs)
      assert report.target_type == "season"
      assert report.season_number == 1
      assert report.title == series.title
    end

    test "rejects a title that is not available (not yours to report)" do
      user = user_fixture()
      # Default fixture status is :requested — not available.
      movie = movie_fixture()

      assert {:error, :not_available} = Issues.create_report(user, report_attrs(movie))
      assert Repo.aggregate(IssueReport, :count) == 0
    end

    test "rejects a season that has not fully landed" do
      user = user_fixture()
      series = series_fixture()
      season = season_fixture(series, season_number: 1)
      # An aired episode with no file → the season is not available.
      _ = episode_fixture(season, file_path: nil, air_date: ~D[2001-01-01])

      attrs = %{
        target_type: "season",
        target_id: series.tmdb_id,
        season_number: 1,
        category: "playback"
      }

      assert {:error, :not_available} = Issues.create_report(user, attrs)
    end

    test "rejects a target that does not exist" do
      user = user_fixture()

      attrs = %{target_type: "movie", target_id: 999_999, category: "other"}
      assert {:error, :not_available} = Issues.create_report(user, attrs)
    end
  end

  describe "create_report/2 — rate bound" do
    test "caps open reports per user" do
      user = user_fixture()

      # Five distinct available movies, each reported once → at the cap.
      for _ <- 1..5 do
        movie = available_movie()
        assert {:ok, _} = Issues.create_report(user, report_attrs(movie))
      end

      sixth = available_movie()
      assert {:error, :too_many_open} = Issues.create_report(user, report_attrs(sixth))

      # A different user is unaffected by the first user's open count.
      other = user_fixture()
      assert {:ok, _} = Issues.create_report(other, report_attrs(sixth))
    end

    test "a resolved report frees a slot" do
      user = user_fixture()
      admin = admin_fixture()

      reports =
        for _ <- 1..5 do
          movie = available_movie()
          {:ok, report} = Issues.create_report(user, report_attrs(movie))
          report
        end

      # At the cap.
      capped = available_movie()
      assert {:error, :too_many_open} = Issues.create_report(user, report_attrs(capped))

      # Resolving one drops the open count below the cap.
      assert {:ok, _} = Issues.resolve(hd(reports), admin)
      assert {:ok, _} = Issues.create_report(user, report_attrs(capped))
    end
  end

  describe "resolve/2 and dismiss/2" do
    setup do
      user = user_fixture()
      admin = admin_fixture()
      movie = available_movie()
      {:ok, report} = Issues.create_report(user, report_attrs(movie))
      %{user: user, admin: admin, report: report}
    end

    test "resolve records the admin and notifies", %{admin: admin, report: report} do
      Cinder.TestNotifier.subscribe()

      assert {:ok, resolved} = Issues.resolve(report, admin)
      assert resolved.status == :resolved
      assert resolved.resolver_id == admin.id

      # The reporter is notified (the Email transport turns this into their email).
      assert_receive {:notify, {:issue_resolved, ^resolved}}
      # No longer in the open queue.
      assert Issues.list_open() == []
    end

    test "dismiss records the admin without a resolved notification", %{
      admin: admin,
      report: report
    } do
      Cinder.TestNotifier.subscribe()

      assert {:ok, dismissed} = Issues.dismiss(report, admin)
      assert dismissed.status == :dismissed
      assert dismissed.resolver_id == admin.id

      assert_receive {:notify, {:issue_dismissed, ^dismissed}}
      # dismiss never emits :issue_resolved (no reporter "it's fixed" email).
      refute_receive {:notify, {:issue_resolved, _}}
    end

    test "a second admin acting on the same report is a no-op (guarded)", %{
      admin: admin,
      report: report
    } do
      other_admin = admin_fixture()

      assert {:ok, _} = Issues.resolve(report, admin)
      # The struct is now stale (:open in memory); the guarded flip matches 0 rows.
      assert {:error, :not_open} = Issues.dismiss(report, other_admin)
    end
  end

  describe "list_open/0 and count_open/0" do
    test "surface only open reports, oldest first, with the requester preloaded" do
      user = user_fixture()
      admin = admin_fixture()
      m1 = available_movie()
      m2 = available_movie()

      {:ok, r1} = Issues.create_report(user, report_attrs(m1))
      {:ok, r2} = Issues.create_report(user, report_attrs(m2))
      {:ok, _} = Issues.resolve(r1, admin)

      assert [open] = Issues.list_open()
      assert open.id == r2.id
      assert open.user.email == user.email
      assert Issues.count_open() == 1
    end
  end

  describe "GDPR" do
    test "a user deletion cascades away their issue reports" do
      user = user_fixture()
      movie = available_movie()
      {:ok, _} = Issues.create_report(user, report_attrs(movie))
      assert Repo.aggregate(IssueReport, :count) == 1

      Repo.delete!(user)
      assert Repo.aggregate(IssueReport, :count) == 0
    end

    test "deleting the resolving admin nilifies resolver_id but keeps the report" do
      user = user_fixture()
      admin = admin_fixture()
      movie = available_movie()
      {:ok, report} = Issues.create_report(user, report_attrs(movie))
      {:ok, resolved} = Issues.resolve(report, admin)
      assert resolved.resolver_id == admin.id

      Repo.delete!(admin)
      kept = Repo.get!(IssueReport, report.id)
      assert kept.resolver_id == nil
      assert kept.status == :resolved
    end

    test "export_for_user/1 returns only the caller's reports as JSON-ready maps" do
      user = user_fixture()
      other = user_fixture()
      mine = available_movie(%{title: "Mine"})
      theirs = available_movie(%{title: "Theirs"})

      {:ok, _} = Issues.create_report(user, report_attrs(mine, %{detail: "mine detail"}))
      {:ok, _} = Issues.create_report(other, report_attrs(theirs))

      assert [row] = Issues.export_for_user(user)
      assert row.title == "Mine"
      assert row.category == :audio
      assert row.detail == "mine detail"
      assert row.status == :open
      assert is_binary(row.inserted_at)
    end
  end
end
