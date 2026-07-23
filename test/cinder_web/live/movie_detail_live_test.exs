defmodule CinderWeb.MovieDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, TitleAlias}
  alias Cinder.Repo

  @moduletag :capture_log

  setup :register_and_log_in_admin
  # Global: the enrich backfill runs in a start_async task (separate process).
  setup :set_mox_global

  setup do
    # Action tests don't care about the enrich backfill (their movies have no TMDB stub);
    # a graceful {:error} keeps the async task from raising an unstubbed-call error. The
    # metadata tests below re-stub get_movie with the specific id, which wins.
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, :nofetch} end)
    # cancel_movie / delete_movie may remove an active download via the client.
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> :ok end)
    :ok
  end

  defp available_movie!(file_path) do
    movie = movie_fixture(%{title: "M", year: 2010})

    {:ok, movie} =
      movie
      |> Ecto.Changeset.change(status: :available, file_path: file_path)
      |> Repo.update()

    movie
  end

  defp stub_details(tmdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         title: "Inception",
         year: 2010,
         poster_path: "/p.jpg",
         imdb_id: "tt1375666",
         original_language: "en",
         overview: "A thief who steals corporate secrets through dream-sharing.",
         runtime: 148,
         genres: ["Action", "Science Fiction"],
         vote_average: 8.4,
         release_date: ~D[2010-07-16]
       }}
    end)
  end

  # A connected detail mount always starts :enrich. Drain it before returning so its DB work cannot
  # outlive the SQL sandbox owner at the end of the test.
  defp live_movie(conn, movie, drain? \\ true) do
    {:ok, view, html} = live(conn, ~p"/movies/#{movie.id}")
    on_exit(fn -> stop_live_view(view) end)

    if drain? do
      render_async(view)
      {:ok, view, render(view)}
    else
      {:ok, view, html}
    end
  end

  defp stop_live_view(view) do
    if Process.alive?(view.pid), do: GenServer.stop(view.pid)
  catch
    :exit, _reason -> :ok
  end

  test "admin changes a movie profile and manages a manual alias", %{conn: conn} do
    movie = movie_fixture()
    {:ok, view, _} = live_movie(conn, movie)

    assert has_element?(view, "#movie-profile-form")

    view
    |> form("#movie-profile-form", %{"media_profile" => "anime"})
    |> render_change()

    assert Repo.reload(movie).media_profile == :anime

    view
    |> form("#movie-alias-form", %{
      "alias" => %{
        "title" => "Kimi no Na wa.",
        "kind" => "romaji",
        "country_code" => "JP",
        "language_code" => "ja"
      }
    })
    |> render_submit()

    assert has_element?(view, "#movie-title-aliases [data-alias='Kimi no Na wa.']")
    assert [alias_record] = Catalog.list_title_aliases(movie)

    refute has_element?(view, "#movie-alias-edit-status")
    refute has_element?(view, "#edit-movie-alias-#{alias_record.id}[phx-click*='focus']")
    assert has_element?(view, "#edit-movie-alias-#{alias_record.id}[phx-click*='push']")

    view
    |> element("#edit-movie-alias-#{alias_record.id}")
    |> render_click()

    assert has_element?(
             view,
             "#movie-alias-edit-status[role='status'][phx-mounted*='focus'][phx-mounted*='#movie-alias-title']",
             "Editing alias Kimi no Na wa."
           )

    view
    |> form("#movie-alias-form", %{
      "alias" => %{
        "id" => alias_record.id,
        "title" => "Your Name.",
        "kind" => "licensed",
        "country_code" => "US",
        "language_code" => "en"
      }
    })
    |> render_submit()

    assert has_element?(view, "#movie-title-aliases [data-alias='Your Name.']")

    view
    |> element("#delete-movie-alias-#{alias_record.id}")
    |> render_click()

    assert Catalog.list_title_aliases(movie) == []
    assert has_element?(view, "#movie-aliases-empty")
  end

  test "the Audio pick offers all four options and drives the Anime audio mode", %{conn: conn} do
    movie = movie_fixture(%{media_profile: :anime})
    {:ok, view, _} = live_movie(conn, movie)

    assert has_element?(view, "#movie-language-form option[value='dual']", "French + original")

    view
    |> form("#movie-language-form", %{"preferred_language" => "dual"})
    |> render_change()

    assert Repo.reload(movie).preferred_language == "dual"
    assert has_element?(view, "#movie-language-form option[value='dual'][selected]")
  end

  test "movie profile and alias events reject forged values and provider aliases are read-only",
       %{
         conn: conn
       } do
    movie = movie_fixture()
    other = movie_fixture()
    {:ok, manual} = Catalog.save_manual_alias(other, %{title: "Other owner"})

    provider =
      %TitleAlias{movie_id: movie.id}
      |> TitleAlias.changeset(%{
        title: "Provider title",
        kind: :alternative,
        source: "tmdb",
        namespace: "alternative_titles",
        precedence: :curated
      })
      |> Repo.insert!()

    {:ok, view, _} = live_movie(conn, movie)

    render_hook(view, "set_media_profile", %{"media_profile" => "forged"})

    render_hook(view, "save_alias", %{
      "alias" => %{"id" => "not-an-id", "title" => "Forged create"}
    })

    render_hook(view, "edit_alias", %{"id" => provider.id})
    render_hook(view, "delete_alias", %{"id" => provider.id})
    render_hook(view, "delete_alias", %{"id" => manual.id})

    assert Repo.reload(movie).media_profile == :auto
    assert Repo.reload(provider).title == "Provider title"
    assert Repo.reload(manual).title == "Other owner"
    refute Enum.any?(Catalog.list_title_aliases(movie), &(&1.title == "Forged create"))
    assert has_element?(view, "[data-alias='Provider title'][data-source='tmdb']")
    refute has_element?(view, "#edit-movie-alias-#{provider.id}")
    refute has_element?(view, "#delete-movie-alias-#{provider.id}")
  end

  test "movie Auto profile shows effective Standard and evidence after metadata enrichment", %{
    conn: conn
  } do
    movie =
      movie_fixture(%{title: "Anime film", media_profile: :auto, original_language: "ja"})

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         title: "Anime film",
         year: 2020,
         poster_path: nil,
         imdb_id: nil,
         original_language: "ja",
         overview: nil,
         runtime: 100,
         genres: ["Animation"],
         vote_average: 7.0,
         release_date: ~D[2020-01-01]
       }}
    end)

    {:ok, view, _} = live_movie(conn, movie, false)
    render_async(view)

    assert Repo.reload(movie).media_profile == :auto

    assert has_element?(
             view,
             "#movie-profile-summary[data-selected='auto'][data-effective='standard']"
           )

    assert has_element?(view, "#movie-profile-summary", "Japanese animation")
  end

  test "refreshes and renders descriptive metadata", %{conn: conn} do
    movie = movie_fixture(%{title: "Inception"})
    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live_movie(conn, movie, false)
    html = render_async(lv)

    assert html =~ "A thief who steals corporate secrets"
    assert html =~ "Action"
    assert html =~ "Science Fiction"
    assert html =~ "148 min"
    assert html =~ "8.4"
  end

  test "refreshes descriptive metadata when reopening an enriched movie", %{conn: conn} do
    movie =
      movie_fixture(%{title: "Inception"})
      |> Ecto.Changeset.change(%{overview: "Old overview", vote_average: 1.0})
      |> Repo.update!()

    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live_movie(conn, movie, false)

    assert render_async(lv) =~ "A thief who steals corporate secrets"
  end

  test "renders the downloaded-file panel from the imported_* fields", %{conn: conn} do
    movie =
      movie_fixture(%{
        title: "Inception",
        status: :available,
        file_path: "/library/Inception (2010)/Inception (2010).mkv",
        imported_resolution: "1080p",
        # 2 GiB → "2.0 GB"
        imported_size: 2_147_483_648,
        imported_source: "BluRay",
        imported_language: "en",
        release_title: "Inception.2010.1080p.BluRay.x264-GRP"
      })

    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live_movie(conn, movie, false)
    html = render_async(lv)

    assert html =~ "Downloaded file"
    assert html =~ "1080p"
    assert html =~ "2.0 GB"
    assert html =~ "BluRay"
    assert html =~ "Inception.2010.1080p.BluRay.x264-GRP"
  end

  test "shows audio + subtitle languages when present", %{conn: conn} do
    movie =
      movie_fixture(%{
        status: :available,
        file_path: "/l/M/M.mkv",
        imported_audio_languages: ["en", "fr"],
        imported_embedded_subtitles: ["en"],
        imported_sidecar_subtitles: ["fr"]
      })

    stub_details(movie.tmdb_id)

    {:ok, lv, html} = live_movie(conn, movie)
    # Scoped to the imported-media-info row (`dt`), not the per-title Audio picker's aria-label.
    assert has_element?(lv, "dt", "Audio")
    assert html =~ "en"
    assert html =~ "fr"
    assert html =~ "embedded"
    assert html =~ "sidecar"
  end

  test "hides the Audio/Subtitles rows when the language lists are empty or nil", %{conn: conn} do
    movie =
      movie_fixture(%{
        status: :available,
        file_path: "/l/M/M.mkv",
        imported_audio_languages: [],
        imported_embedded_subtitles: nil,
        imported_sidecar_subtitles: nil
      })

    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live_movie(conn, movie)
    refute has_element?(lv, "dt", "Audio")
    refute has_element?(lv, "dt", "Subtitles")
  end

  test "a non-integer id redirects to the library instead of crashing", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/library"}}} = live(conn, ~p"/movies/not-an-id")
  end

  test "a stale {:movie_updated} broadcast doesn't blank the metadata (re-reads fresh)", %{
    conn: conn
  } do
    # `movie` is captured pre-enrichment (vote_average/overview nil) — the same stale snapshot an
    # unguarded transition/2 echoes on its broadcast.
    movie = movie_fixture(%{title: "Inception"})
    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live_movie(conn, movie, false)
    assert render_async(lv) =~ "A thief who steals corporate secrets"

    # Unguarded transition on the stale struct broadcasts {:movie_updated, stale} (nil metadata).
    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    html = render(lv)

    assert html =~ "A thief who steals corporate secrets",
           "metadata must survive a stale broadcast"

    assert html =~ "Downloading"
  end

  test "renders download progress", %{conn: conn} do
    movie = movie_fixture(%{status: :downloading})

    {:ok, _} =
      Catalog.update_movie_download_metrics(movie, %{
        download_progress: 0.42,
        download_speed: 1_500_000,
        download_eta: 90
      })

    {:ok, lv, _html} = live_movie(conn, movie)
    assert render(lv) =~ "42%"
  end

  test "a movie whose TMDB runtime is 0 hides the runtime chip", %{conn: conn} do
    movie = movie_fixture(%{title: "Obscure"})

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         title: "Obscure",
         year: 2010,
         poster_path: nil,
         imdb_id: nil,
         original_language: "en",
         overview: "No runtime on file.",
         runtime: 0,
         genres: [],
         vote_average: 6.0,
         release_date: ~D[2010-01-01]
       }}
    end)

    {:ok, lv, _html} = live_movie(conn, movie, false)
    html = render_async(lv)

    refute html =~ "0 min"
  end

  # --- console: cancel / delete (relocated from /library) ---

  test "cancels an active movie through the confirm step", %{conn: conn} do
    movie = movie_fixture(%{title: "Tenet"})
    {:ok, lv, _html} = live_movie(conn, movie)

    lv |> element("button", "Cancel") |> render_click()
    lv |> element("#confirm-cancel-movie button", "Cancel movie") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :cancelled
  end

  test "deletes an inactive movie and redirects to the library", %{conn: conn} do
    movie = movie_fixture(%{title: "Old"})
    {:ok, _} = Catalog.transition(movie, %{status: :cancelled})
    {:ok, lv, _html} = live_movie(conn, movie)

    lv |> element("button", "Delete") |> render_click()
    lv |> element("#confirm-delete-movie button", "Delete") |> render_click()

    assert_redirect(lv, ~p"/library")
    assert Catalog.get_movie_by_id(movie.id) == nil
  end

  test "deleting a movie with the delete-files box ticked unlinks the file", %{conn: conn} do
    movie = available_movie!("/tmp/cinder-test-library/M (2010)/M (2010).mkv")

    expect(
      Cinder.Library.FilesystemMock,
      :rm,
      fn "/tmp/cinder-test-library/M (2010)/M (2010).mkv" -> :ok end
    )

    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live_movie(conn, movie)

    lv |> element("button", "Delete") |> render_click()
    lv |> element("input[phx-click=toggle_delete_files]") |> render_click()
    lv |> element("#confirm-delete-movie button", "Delete") |> render_click()

    refute Repo.get(Cinder.Catalog.Movie, movie.id)
  end

  test "deleting a movie without ticking the box leaves the file (no FS call)", %{conn: conn} do
    movie = available_movie!("/tmp/x.mkv")
    {:ok, lv, _html} = live_movie(conn, movie)

    lv |> element("button", "Delete") |> render_click()
    lv |> element("#confirm-delete-movie button", "Delete") |> render_click()

    refute Repo.get(Cinder.Catalog.Movie, movie.id)
  end

  # --- console: retry / better-match / cancel-upgrade / language (relocated from /activity) ---

  test "a parked movie shows Retry that re-queues it to :requested", %{conn: conn} do
    movie = movie_fixture(%{title: "Tenet"})
    {:ok, _} = Catalog.transition(movie, %{status: :no_match})

    {:ok, lv, _html} = live_movie(conn, movie)
    lv |> element("button", "Retry") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :requested
  end

  test "a held normal verification failure retries preserved content instead of search", %{
    conn: conn
  } do
    movie = verification_held_movie!(:download)
    {:ok, lv, _html} = live_movie(conn, movie)

    assert has_element?(lv, "span.badge-warning", "Needs verification")
    assert has_element?(lv, "button", "Retry verification")
    assert has_element?(lv, "button", "Cancel")
    refute has_element?(lv, "button", "Find a better match")

    lv |> element("button", "Retry verification") |> render_click()

    assert %Movie{
             status: :downloaded,
             import_attempts: 0,
             verification_hold_origin: nil,
             download_id: "HASH-HELD-download",
             file_path: "/downloads/Anime Movie.mkv"
           } = Catalog.get_movie_by_id(movie.id)
  end

  test "a held upgrade exposes Retry and safe Cancel upgrade while preserving the live file", %{
    conn: conn
  } do
    movie = verification_held_movie!(:upgrade)
    {:ok, lv, _html} = live_movie(conn, movie)

    assert has_element?(lv, "span.badge-warning", "Needs verification")
    assert has_element?(lv, "button", "Retry verification")
    assert has_element?(lv, "button", "Cancel upgrade")
    refute has_element?(lv, "button", "Find a better match")

    lv |> element("button", "Cancel upgrade") |> render_click()

    assert %Movie{
             status: :available,
             verification_hold_origin: nil,
             download_id: nil,
             file_path: "/library/Anime Movie.mkv",
             imported_resolution: "720p"
           } = Catalog.get_movie_by_id(movie.id)
  end

  test "an in-flight movie shows no Retry button", %{conn: conn} do
    movie = movie_fixture(%{title: "Sicario"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    {:ok, lv, _html} = live_movie(conn, movie)
    refute has_element?(lv, "button", "Retry")
  end

  test "Find a better match opens the panel; grabbing transitions the movie to :upgrading",
       %{conn: conn} do
    movie =
      movie_fixture(%{
        title: "Metropolis",
        status: :available,
        imdb_id: "tt1",
        file_path: "/lib/Metropolis (1927)/Metropolis (1927).mkv"
      })

    stub(Cinder.Acquisition.IndexerMock, :search, fn _imdb ->
      {:ok,
       [%{title: "Better 1080p", size: 5_000_000_000, protocol: :torrent, download_url: "u"}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "dl-x"} end)
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    {:ok, lv, _html} = live_movie(conn, movie)

    lv |> element("button", "Find a better match") |> render_click()
    assert render_async(lv) =~ "Better 1080p"

    # An :available movie routes through the replace confirm before the grab.
    lv |> element("#ms-movie-#{movie.id} button", "Grab") |> render_click()
    lv |> element("button", "Replace file") |> render_click()

    assert render(lv) =~ "Grabbing the selected release"
    assert Catalog.get_movie_by_id(movie.id).status == :upgrading
  end

  test "Cancel upgrade reverts an :upgrading movie to :available", %{conn: conn} do
    movie =
      movie_fixture(%{
        title: "Nosferatu",
        status: :upgrading,
        imdb_id: "tt2",
        download_id: "h-up",
        download_protocol: :torrent,
        file_path: "/lib/Nosferatu (1922)/Nosferatu (1922).mkv"
      })

    stub(Cinder.Download.ClientMock, :remove, fn "h-up", _opts -> :ok end)

    {:ok, lv, _html} = live_movie(conn, movie)
    lv |> element("button", "Cancel upgrade") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :available
  end

  test "changing the language select updates the movie's preferred language", %{conn: conn} do
    movie = movie_fixture(%{title: "Arrival"})
    {:ok, lv, _html} = live_movie(conn, movie)

    lv
    |> form("#movie-language-form", %{"preferred_language" => "french"})
    |> render_change()

    assert Catalog.get_movie_by_id(movie.id).preferred_language == "french"
  end

  defp verification_held_movie!(origin) do
    file_path =
      if origin == :upgrade,
        do: "/library/Anime Movie.mkv",
        else: "/downloads/Anime Movie.mkv"

    movie =
      movie_fixture(%{
        title: "Anime Movie",
        status: :import_failed,
        download_id: "HASH-HELD-#{origin}",
        download_protocol: :torrent,
        release_title: "[Group] Anime Movie",
        file_path: file_path,
        imported_resolution: "720p"
      })

    {:ok, held} =
      Catalog.transition(movie, %{
        status: :import_failed,
        import_attempts: 10,
        verification_hold_origin: origin,
        release_policy_snapshot: %{
          "version" => 1,
          "required_audio_languages" => ["ja", "fr"],
          "required_embedded_subtitle_languages" => [],
          "release_group" => "group",
          "release_title" => movie.release_title
        }
      })

    Repo.reload!(held)
  end
end
