unless Code.ensure_loaded?(Cinder.Repo.Migrations.CreateNamedMediaProfiles) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260815175259_create_named_media_profiles.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.CreateNamedMediaProfilesTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.CreateNamedMediaProfiles
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  test "seeds profiles and backfills explicit legacy selections" do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-profile-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database, pool_size: 1, telemetry_prefix: [:cinder, :profile_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    query!("CREATE TABLE movies (id INTEGER PRIMARY KEY, media_profile TEXT NOT NULL)")
    query!("CREATE TABLE series (id INTEGER PRIMARY KEY, media_profile TEXT NOT NULL)")

    query!("""
    CREATE TABLE requests (
      id INTEGER PRIMARY KEY,
      target_type TEXT NOT NULL,
      proposed_media_profile TEXT
    )
    """)

    query!("INSERT INTO movies (id, media_profile) VALUES (1, 'standard'), (2, 'auto')")
    query!("INSERT INTO series (id, media_profile) VALUES (1, 'anime'), (2, 'auto')")

    query!("""
    INSERT INTO requests (id, target_type, proposed_media_profile)
    VALUES (1, 'movie', 'anime'), (2, 'season', 'standard'), (3, 'movie', NULL)
    """)

    :ok = Ecto.Migrator.up(Repo, 20_260_815_175_259, CreateNamedMediaProfiles, log: false)

    assert %{
             rows: [
               ["movies", "Anime"],
               ["movies", "Standard"],
               ["tv", "Anime"],
               ["tv", "Standard"]
             ]
           } =
             query!("SELECT kind, name FROM media_profiles ORDER BY kind, name")

    assert %{rows: [[1, "Standard"], [2, nil]]} =
             query!("""
             SELECT movies.id, media_profiles.name
             FROM movies LEFT JOIN media_profiles ON media_profiles.id = movies.profile_id
             ORDER BY movies.id
             """)

    assert %{rows: [[1, "Anime"], [2, nil]]} =
             query!("""
             SELECT series.id, media_profiles.name
             FROM series LEFT JOIN media_profiles ON media_profiles.id = series.profile_id
             ORDER BY series.id
             """)

    assert %{rows: [[1, "movies", "Anime"], [2, "tv", "Standard"], [3, nil, nil]]} =
             query!("""
             SELECT requests.id, media_profiles.kind, media_profiles.name
             FROM requests
             LEFT JOIN media_profiles ON media_profiles.id = requests.proposed_profile_id
             ORDER BY requests.id
             """)

    assert_raise Exqlite.Error, ~r/movies_profile_integrity/, fn ->
      query!("""
      UPDATE movies
      SET profile_id = (SELECT id FROM media_profiles WHERE kind = 'tv' AND name = 'Standard')
      WHERE id = 1
      """)
    end

    assert_raise Exqlite.Error, ~r/movies_profile_integrity/, fn ->
      query!("""
      INSERT INTO movies (id, media_profile, profile_id)
      SELECT 4, 'standard', id FROM media_profiles WHERE kind = 'tv' AND name = 'Standard'
      """)
    end

    assert_raise Exqlite.Error, ~r/series_profile_integrity/, fn ->
      query!("""
      UPDATE series
      SET profile_id = (SELECT id FROM media_profiles WHERE kind = 'tv' AND name = 'Standard')
      WHERE id = 1
      """)
    end

    assert_raise Exqlite.Error, ~r/requests_profile_integrity/, fn ->
      query!("""
      UPDATE requests
      SET proposed_media_profile = 'standard'
      WHERE id = 1
      """)
    end

    assert_raise Exqlite.Error, ~r/requests_profile_integrity/, fn ->
      query!("UPDATE requests SET target_type = 'season' WHERE id = 1")
    end

    assert_raise Exqlite.Error, ~r/media_profiles_references_integrity/, fn ->
      query!("""
      UPDATE media_profiles SET handling = 'anime'
      WHERE kind = 'movies' AND name = 'Standard'
      """)
    end

    assert %{num_rows: 1} =
             query!("INSERT INTO movies (id, media_profile, profile_id) VALUES (3, 'auto', NULL)")

    assert %{num_rows: 1} =
             query!("""
             INSERT INTO requests (id, target_type, proposed_media_profile, proposed_profile_id)
             VALUES (4, 'movie', NULL, NULL)
             """)
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
