# Serves the dev app with a fake indexer source, so the movie page's manual-search panel can be
# checked in a browser with results, a search report and errors chosen here. Run it from the repo
# root, with MIX_ENV=dev (any other env stops it before it writes):
#
#     PHX_SERVER=true PORT=4123 MIX_ENV=dev mix run --no-start scripts/dev-manual-search.exs
#
# It migrates the dev database first and prints READY once the server is up. Sign in as
# admin@example.com / cinder-dev-password (made on a database with no user), then open
# /movies/<id> for each MOVIE line it prints, wait a few seconds for the page to connect, and
# press "Find a better match":
#
# - tt9000001: one row with an indexer name, and a report naming a timed-out indexer, one
#   backing off for an hour and one at its limit for three days;
# - tt9000002: `{:error, {:no_indexer_answered, report}}` with the same report;
# - tt9000003: `{:error, {:prowlarr_status, 500}}`.
#
# Edit `DevManualSearch.Source` for another case: each callback of
# `Cinder.Acquisition.IndexerSource` answers here. The script seeds movies only, so a season's or
# a book's panel also needs a series or a book in the dev database. The household time zone is
# Europe/Paris, unless /settings stored one: a stored zone replaces it when the app starts. A
# /settings save while it runs writes the source the database stores back over the fake one when
# the database stores an `indexer_source` row: restart the script then.
defmodule DevManualSearch.Source do
  @behaviour Cinder.Acquisition.IndexerSource

  alias Cinder.Acquisition.IndexerSource.Report

  defp report do
    now = DateTime.utc_now()

    Report.new()
    |> Report.put({"native", 1}, "NZBgeek", :asked)
    |> Report.put({"native", 2}, "DrunkenSlug", {:failed, :timeout})
    |> Report.put({"native", 3}, "AltHub", {:skipped, {:backoff, DateTime.add(now, 3600)}})
    |> Report.put({"native", 4}, "Tabula", {:failed, {:limit, DateTime.add(now, 3 * 86_400)}})
  end

  @impl true
  def search("tt9000001") do
    row = %{
      title: "Seed Movie 1 2024 1080p WEB-DL x264-GRP",
      size: 4_000_000_000,
      protocol: :usenet,
      download_url: "http://fake.invalid/1",
      indexer_name: "NZBgeek"
    }

    {:ok, [row], report()}
  end

  def search("tt9000002"), do: {:error, {:no_indexer_answered, report()}}
  def search("tt9000003"), do: {:error, {:prowlarr_status, 500}}
  def search(_imdb_id), do: {:ok, []}

  @impl true
  def search_movie_query(_query, _opts), do: {:ok, []}
  @impl true
  def search_tv_query(_query, _opts), do: {:ok, []}
  @impl true
  def search_tv(_tvdb_id, _title, _season), do: {:ok, []}
  @impl true
  def search_ebook(_author, _title, _opts), do: {:ok, []}
  @impl true
  def search_ebook_query(_query, _opts), do: {:ok, []}
  @impl true
  def search_audiobook(_author, _title, _opts), do: {:ok, []}
  @impl true
  def search_audiobook_query(_query, _opts), do: {:ok, []}
  @impl true
  def health, do: :ok
  @impl true
  def fetch_download(_url, _source_origin, _opts), do: {:error, :dev_fake_source}
end

if Mix.env() != :dev, do: Mix.raise("scripts/dev-manual-search.exs runs with MIX_ENV=dev only")

{:ok, _, _} = Ecto.Migrator.with_repo(Cinder.Repo, &Ecto.Migrator.run(&1, :up, all: true))

Application.put_env(:cinder, :indexer_source, DevManualSearch.Source)
Application.put_env(:cinder, :household_timezone, "Europe/Paris")
{:ok, _} = Application.ensure_all_started(:cinder)
# The boot's settings overlay keeps a module set before it starts, unless the database stores an
# `indexer_source` row, whose source it writes instead (`Shape.running_indexer_source/3`).
Application.put_env(:cinder, :indexer_source, DevManualSearch.Source)

alias Cinder.Accounts.User
alias Cinder.Catalog.Movie
alias Cinder.Repo

unless Repo.exists?(User) do
  %User{}
  |> User.registration_changeset(
    %{email: "admin@example.com", password: "cinder-dev-password"},
    validate_unique: false
  )
  |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second), role: :admin, active: true)
  |> Repo.insert!()

  Cinder.Settings.mark_setup_complete()
end

for {imdb_id, n} <- [{"tt9000001", 1}, {"tt9000002", 2}, {"tt9000003", 3}],
    is_nil(Repo.get_by(Movie, imdb_id: imdb_id)) do
  Repo.insert!(%Movie{
    tmdb_id: 9_000_000 + n,
    imdb_id: imdb_id,
    title: "Seed Movie #{n}",
    year: 2024,
    status: :available,
    file_path: "/nonexistent/Seed Movie #{n} (2024).mkv"
  })
end

for movie <- Repo.all(Movie), movie.imdb_id in ["tt9000001", "tt9000002", "tt9000003"] do
  IO.puts("MOVIE #{movie.id} #{movie.imdb_id}")
end

IO.puts("READY")
Process.sleep(:infinity)
