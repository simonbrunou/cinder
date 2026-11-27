defmodule Cinder.DevSeedTest do
  # The dev seed (`priv/repo/seeds.exs`) runs only in the dev env, so these tests set `Mix.env/1`
  # around each run: a process-global setting, hence async: false. The seed also saves the
  # `setup_complete` setting, which rewrites the `Cinder.Settings.env_keys/0` keys that
  # `reset_cinder_env/1` restores. On #1638 `Catalog.create_grab/5` opened its
  # `Cinder.GuardedWrite.transaction/2` frame inside the seed's raw `Repo.transaction/1`, which
  # raised and rolled the whole seed back.
  use CinderWeb.ConnCase, async: false

  import ExUnit.CaptureIO
  import Phoenix.LiveViewTest

  alias Cinder.Accounts.User
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Season, Series}
  alias Cinder.Repo
  alias Cinder.Settings

  @seed "priv/repo/seeds.exs"

  setup :reset_cinder_env

  test "the dev branch seeds an admin, a finished setup and one undecided grab file", %{
    conn: conn
  } do
    output = capture_io(fn -> run_seed(:dev) end)

    assert output =~
             "priv/repo/seeds.exs: seeded; log in as admin@example.com / cinder-dev-password"

    assert [%User{email: "admin@example.com", role: :admin, active: true} = admin] =
             Repo.all(User)

    assert admin.confirmed_at
    assert Settings.get("setup_complete") == "true"

    assert [%Series{title: "Seed Show"} = series] = Repo.all(Series)
    assert [%Season{season_number: 1} = season] = Repo.all(Season)
    assert season.series_id == series.id
    assert [%Episode{episode_number: 1, title: "Pilot"} = episode] = Repo.all(Episode)
    assert episode.season_id == season.id

    # A downloaded grab is one with its content path recorded (`Catalog.mark_grab_downloaded/2`).
    assert [
             %Grab{
               download_id: "dev-seed-1",
               release_title: "Seed.Show.S01E01.1080p.WEB-GRP",
               content_path: "/tmp/cinder-dev-seed/Seed.Show.S01E01"
             } = grab
           ] = Repo.all(Grab)

    assert Repo.reload!(episode).grab_id == grab.id

    assert [%GrabFile{relative_path: "Seed.Show.S01E01.Extras.mkv", decision: nil} = file] =
             Repo.all(GrabFile)

    assert file.grab_id == grab.id

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/activity")

    assert has_element?(view, "#grab-#{grab.id}", "Needs mapping")
    assert has_element?(view, "#grab-#{grab.id}", "Seed.Show.S01E01.Extras.mkv")
  end

  test "a seed whose last write fails writes nothing and puts Mix.env back" do
    # The grab file is the seed's last write, after the admin, the setting, the series and the
    # grab. The trigger lives in the test's sandbox transaction, which the test's end rolls back.
    Repo.query!("""
    CREATE TRIGGER dev_seed_test_refuse_grab_file BEFORE INSERT ON grab_files
    BEGIN SELECT RAISE(ABORT, 'dev seed test: grab file refused'); END
    """)

    error = assert_raise Exqlite.Error, fn -> capture_io(fn -> run_seed(:dev) end) end
    assert error.message =~ "dev seed test: grab file refused"

    assert Mix.env() == :test
    assert Repo.all(User) == []
    assert Settings.get("setup_complete") == nil
    assert Repo.all(Series) == []
    assert Repo.all(Season) == []
    assert Repo.all(Episode) == []
    assert Repo.all(Grab) == []
    assert Repo.all(GrabFile) == []
  end

  test "the seed skips a database that already has users" do
    Cinder.AccountsFixtures.user_fixture()

    assert capture_io(fn -> run_seed(:dev) end) =~
             "priv/repo/seeds.exs: the database already has users, skipped"

    assert Repo.all(Series) == []
    assert Settings.get("setup_complete") == nil
  end

  test "the seed skips the test and prod envs" do
    for env <- [:test, :prod] do
      assert capture_io(fn -> run_seed(env) end) =~
               "priv/repo/seeds.exs: dev only, skipped in #{env}"
    end

    assert Repo.all(User) == []
    assert Repo.all(Series) == []
  end

  defp run_seed(env) do
    previous = Mix.env()
    Mix.env(env)

    try do
      Code.eval_file(@seed)
    after
      Mix.env(previous)
    end
  end
end
