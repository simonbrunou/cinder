# Dev seed: data to look at a page in a local browser. `mix setup` and `mix ecto.setup` run it;
# run it again with:
#
#     mix run priv/repo/seeds.exs
#
# It creates an admin (printed below), marks the first-run wizard complete so admin pages stop
# redirecting to /setup, and adds one series with one episode whose downloaded grab holds one
# undecided file, which /activity lists with a "Needs mapping" badge and its resolve and discard
# actions. The TV poller leaves such a grab alone until an operator decides the file. The download
# folder it names does not exist, so the page is for looking at: deciding the file imports
# nothing. It runs only in the dev env and only on a database with no users, so it never touches a
# database someone already uses, and it writes everything in one transaction. To try the
# first-run wizard, start from an empty database instead:
# `mix ecto.drop && mix ecto.create && mix ecto.migrate`.

alias Cinder.Accounts.User
alias Cinder.Catalog
alias Cinder.Catalog.{Episode, GrabFile, Season, Series}
alias Cinder.Repo

email = "admin@example.com"
password = "cinder-dev-password"

cond do
  Mix.env() != :dev ->
    IO.puts("priv/repo/seeds.exs: dev only, skipped in #{Mix.env()}")

  Repo.exists?(User) ->
    IO.puts("priv/repo/seeds.exs: the database already has users, skipped")

  true ->
    Repo.transaction(fn ->
      %User{}
      |> User.registration_changeset(%{email: email, password: password}, validate_unique: false)
      |> Ecto.Changeset.change(
        confirmed_at: DateTime.utc_now(:second),
        role: :admin,
        active: true
      )
      |> Repo.insert!()

      Cinder.Settings.mark_setup_complete()

      series =
        Repo.insert!(%Series{
          tmdb_id: 999_000_001,
          title: "Seed Show",
          year: 2024,
          monitored: true,
          monitor_strategy: :all
        })

      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

      episode =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 1,
          title: "Pilot",
          monitored: true,
          air_date: ~D[2024-01-01]
        })

      {:ok, grab} =
        Catalog.create_grab(
          "dev-seed-1",
          :torrent,
          [episode.id],
          "Seed.Show.S01E01.1080p.WEB-GRP"
        )

      {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/tmp/cinder-dev-seed/Seed.Show.S01E01")

      %GrabFile{}
      |> GrabFile.changeset(%{
        grab_id: grab.id,
        relative_path: "Seed.Show.S01E01.Extras.mkv",
        size: 104_857_600,
        device: 1,
        inode: 1
      })
      |> Repo.insert!()
    end)

    IO.puts("priv/repo/seeds.exs: seeded; log in as #{email} / #{password}")
end
