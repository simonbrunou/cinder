defmodule CinderWeb.SetupLiveTest do
  # async: false — the wizard saves config (mutating global env) and tests services.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.NewznabFixtures, only: [indexer!: 2]
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, IndexerStatus, TestRunner}
  alias Cinder.{ConfigCase, Indexers, Settings}
  alias Cinder.Test.Rendezvous

  setup :set_mox_global
  setup :reset_cinder_env

  @indexer_help "Cinder searches your indexers itself (Built-in), or through Prowlarr if you already run it. For Built-in, add each indexer below; Cinder tests each enabled indexer when you add it. For Prowlarr, add your indexers there, then copy its URL and API key from Settings > General."
  @coverage "No usable indexer uses the same protocol as a working download client."

  # Stubs every service green. Submitting the setup form saves a choice for the media server,
  # for each download protocol and for the indexer source (the form sends every select's value),
  # which wires the real Jellyfin, qBittorrent, SABnzbd and Prowlarr clients: their health runs
  # through the Req.Test stubs below. TMDB and the library roots stay on their Mox mocks, and the
  # indexer and client mocks answer only before the first save. Each setup target's probe calls
  # `answer` once, on a call its health check makes exactly once, and fails when `answer` returns
  # an error.
  defp stub_all_services_ok(answer \\ fn -> :ok end) do
    stub(Cinder.Catalog.TMDBMock, :health, answer)
    stub(Cinder.Acquisition.IndexerMock, :health, answer)
    stub(Cinder.Download.ClientMock, :health, answer)
    stub(Cinder.Download.SabnzbdClientMock, :health, answer)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> answer.() end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/api/v2/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        "/api/v2/app/webapiVersion" ->
          reply(conn, answer, &Req.Test.text(&1, "2.8.5"))
      end
    end)

    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case conn.params["mode"] do
        "queue" ->
          reply(conn, answer, &Req.Test.json(&1, %{"queue" => %{"slots" => []}}))

        "get_config" ->
          Req.Test.json(conn, %{"config" => %{"misc" => %{}}})
      end
    end)

    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      reply(conn, answer, &Req.Test.json(&1, %{}))
    end)

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      reply(conn, answer, &Req.Test.json(&1, []))
    end)
  end

  # Sends the canned response once `answer` returns `:ok`, and a 503 when it returns an error.
  defp reply(conn, answer, respond) do
    case answer.() do
      :ok -> respond.(conn)
      {:error, reason} -> Plug.Conn.send_resp(conn, 503, inspect(reason))
    end
  end

  defp sleep_ok(ms) do
    Process.sleep(ms)
    :ok
  end

  # Enables qBittorrent + Jellyfin and searches through Prowlarr, so the loop can validate green.
  @valid_params %{
    "torrent_client" => "qbittorrent",
    "media_server_type" => "jellyfin",
    "indexer_source" => "prowlarr"
  }
  # Book/audiobook roots have no env bootstrap (`Cinder.Settings`'s one-time bootstrap snapshot
  # is cached in `:persistent_term` at first read and never refreshed mid-suite, so mutating
  # `Application.put_env(:cinder, :books_library_path, ...)` inside a test is unreliable — the
  # cache may already be frozen at `nil`/`[]` from an earlier, unrelated test). Submitting these
  # through the form instead persists a real `Cinder.Settings` DB row, which
  # `apply_kind_config/2` always reads in preference to the cached bootstrap fallback — the same
  # path a real operator's wizard submission takes.
  @valid_params_with_books Map.merge(@valid_params, %{
                             "books_library_path" => "/tmp/cinder-test-books-library",
                             "audiobooks_library_path" => "/tmp/cinder-test-audiobooks-library"
                           })

  test "an admin validates services and finishes setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv |> form("#setup-form", @valid_params_with_books) |> render_submit()
    assert has_element?(lv, "#finish-setup:not([disabled])")

    lv |> element("#finish-setup") |> render_click()
    assert Cinder.Settings.setup_complete?()
  end

  test "the first-run wizard excludes settings-only controls", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, ~p"/setup")

    # move_on_import is a /settings-only advanced toggle (it deletes a download); a
    # first-run operator hasn't validated their hardlink topology yet, so keep it out.
    refute html =~ ~s(name="move_on_import")
    refute has_element?(lv, "#anime-settings")
    # But the wizard still shows the library paths it needs to validate.
    assert html =~ ~s(name="movies_library_path")
    assert html =~ ~s(name="movies_anime_library_path")
    assert html =~ ~s(name="books_library_path")
    assert html =~ ~s(name="audiobooks_library_path")
    refute html =~ ~s(name="books_anime_library_path")
  end

  test "book and audiobook roots are required to finish setup, like the video ones", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")

    assert has_element?(lv, "button[phx-value-target=ebook_library]", "Test Ebooks library")

    assert has_element?(
             lv,
             "button[phx-value-target=audiobook_library]",
             "Test Audiobooks library"
           )

    # The checklist lists all four library roots, book and video alike.
    assert has_element?(lv, "#setup-checklist", "Movies library")
    assert has_element?(lv, "#setup-checklist", "TV library")
    assert has_element?(lv, "#setup-checklist", "Ebooks library")
    assert has_element?(lv, "#setup-checklist", "Audiobooks library")

    # Neither book root is configured yet: Finish stays locked exactly like an unset/unwritable
    # video root would, proving the requirement is enforced and not merely displayed.
    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, "#finish-setup[disabled]")

    lv |> form("#setup-form", @valid_params_with_books) |> render_submit()
    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "the wizard gives required sections an ordered path from a clear starting point", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    assert has_element?(
             lv,
             "#setup-required-steps",
             "Complete these 5 required steps in order"
           )

    assert has_element?(lv, "#setup-step-1", "Start here")

    for {step, group, label} <- [
          {1, "tmdb", "TMDB"},
          {2, "indexer", "Indexer"},
          {3, "download", "Download clients"},
          {4, "media_server", "Media server"},
          {5, "library", "Library paths"}
        ] do
      assert has_element?(lv, "#setup-step-#{step}", label)
      assert has_element?(lv, "#settings-group-#{group}[data-setup-step=\"#{step}\"]")
    end

    refute has_element?(lv, "#setup-step-6")

    for group <- ~w(migration audiobook_server releases subtitles books notifications accounts) do
      assert has_element?(lv, "#settings-group-#{group}[data-setup-optional=true]", "Optional")
    end
  end

  test "the required-steps heading has a French plural", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    {:ok, admin} = Cinder.Accounts.update_user_locale(admin, %{locale: "fr"})
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    # The English heading test pins the count; this one pins the French plural.
    assert has_element?(
             lv,
             "#setup-required-steps-title",
             "étapes obligatoires dans l’ordre"
           )
  end

  test "every setup section explains its purpose and credential sources are linked", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    for {group, _label} <- Cinder.Settings.groups() do
      assert has_element?(lv, "#settings-group-#{group} .setup-section-help")
    end

    assert has_element?(lv, "#settings-group-tmdb .setup-section-help", "movie and TV metadata")
    assert has_element?(lv, "#settings-group-indexer .setup-section-help", @indexer_help)

    assert has_element?(
             lv,
             "#settings-group-library .setup-section-help",
             "reusing disk space when possible"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=import_roots]",
             "Download folders"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "Folders where your download clients save completed files"
           )

    assert has_element?(
             lv,
             ~s|#import_roots[aria-describedby="import_roots-help"]|
           )

    assert has_element?(
             lv,
             "#import_roots-help",
             "Folders where your download clients save completed files"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=movies_library_path]",
             "Movies library folder"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "reuses the download's disk space instead of making another full copy"
           )

    for kind <- ~w(movies tv) do
      assert has_element?(
               lv,
               ~s|##{kind}_library_path[aria-describedby="library-paths-help"]|
             )
    end

    assert has_element?(
             lv,
             "#library-paths-help",
             "reuses the download's disk space instead of making another full copy"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=ffprobe_bin]",
             "ffprobe media analysis tool"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "Cinder uses ffprobe to check audio and subtitle languages after import"
           )

    assert has_element?(
             lv,
             ~s|#ffprobe_bin[aria-describedby="ffprobe_bin-help"]|
           )

    assert has_element?(
             lv,
             "#ffprobe_bin-help",
             "Cinder uses ffprobe to check audio and subtitle languages after import"
           )

    for jargon <- ["Download import roots", "hardlink", "ffprobe binary", "filesystem root"] do
      refute has_element?(lv, "#settings-group-library", jargon)
    end

    for {group, url} <- [
          {"tmdb", "https://developer.themoviedb.org/docs/authentication-application"},
          {"indexer", "https://wiki.servarr.com/prowlarr/settings"},
          {"download", "https://www.qbittorrent.org/"},
          {"media_server", "https://www.plex.tv/media-server-downloads/"},
          {"subtitles",
           "https://opensubtitles.stoplight.io/docs/opensubtitles-api/e3750fd63a100-getting-started"},
          {"notifications", "https://docs.discord.com/developers/resources/webhook"}
        ] do
      assert has_element?(
               lv,
               "#settings-group-#{group} .setup-section-help a[href=\"#{url}\"][target=_blank][rel=\"noopener noreferrer\"]"
             )
    end

    assert has_element?(
             lv,
             "#settings-group-media_server .setup-section-help a[href=\"https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/\"]"
           )
  end

  test "a service that fails keeps Finish disabled", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    Req.Test.stub(Cinder.ProwlarrStub, &Req.Test.transport_error(&1, :econnrefused))

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", @valid_params) |> render_submit()

    assert has_element?(lv, "#finish-setup[disabled]")
    refute Cinder.Settings.setup_complete?()
  end

  test "a download group whose every client failed reads as none reachable", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> {:error, :econnrefused} end)
    Req.Test.stub(Cinder.QBittorrentStub, &Req.Test.transport_error(&1, :econnrefused))
    Req.Test.stub(Cinder.SabnzbdStub, &Req.Test.transport_error(&1, :econnrefused))

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", @valid_params_with_books) |> render_submit()

    assert has_element?(lv, "#setup-check-group-download", "None reachable")
    assert has_element?(lv, "#finish-setup[disabled]")
  end

  test "a SABnzbd configuration warning remains reachable during setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{
            "config" => %{
              "misc" => %{"folder_max_length" => 60, "no_dupes" => 0, "no_series_dupes" => 0}
            }
          })
      end
    end)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv
    |> form(
      "#setup-form",
      Map.merge(@valid_params_with_books, %{
        "torrent_client" => "disabled",
        "media_server_type" => "jellyfin"
      })
    )
    |> render_submit()

    assert has_element?(lv, "#finish-setup:not([disabled])")
    # The warning passes, and its reason shows beside its badge, as on /settings (#1663).
    assert has_element?(lv, "#test-target-usenet")
    assert has_element?(lv, "#test-reason-usenet.text-warning", "Folder name limit is 60")
  end

  test "Save & validate checks the setup targets at once, not one after another", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    # Every setup target's probe reaches one stubbed call (nine today), and each call waits
    # there until all of them have arrived. Timing the click instead failed on a loaded runner
    # (#1046).
    targets = Cinder.Health.targets(setup: :required) ++ Cinder.Health.targets(setup: :any)
    rendezvous = Rendezvous.new(length(targets))
    stub_all_services_ok(fn -> Rendezvous.arrive(rendezvous) end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", @valid_params_with_books) |> render_submit()

    # Finish alone does not prove it: the download group stays green with one client up.
    assert Rendezvous.result(rendezvous) == %{arrived: length(targets), met: length(targets)}
    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "a setup target that outlasts the timeout budget reads as timed out", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    # The indexer alone gets the shrunk budget (`reset_cinder_env` restores it), and Prowlarr never
    # answers: the probe ends only when the budget kills it.
    Application.put_env(:cinder, :health_probe_timeout_ms, %{"indexer" => 200})
    Req.Test.stub(Cinder.ProwlarrStub, fn _conn -> Process.sleep(:infinity) end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", @valid_params_with_books) |> render_submit()

    assert has_element?(lv, "#setup-check-indexer", "Timed out")
    assert has_element?(lv, "#setup-check-tmdb .hero-check-circle")
    assert has_element?(lv, "#setup-check-group-download .hero-check-circle")
    assert has_element?(lv, "#finish-setup[disabled]")
  end

  test "the checklist has a row per required target and one for the download clients", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    rows = [
      {"tmdb", "TMDB"},
      {"indexer", "Indexers"},
      {"media_server", "Media server"},
      {"movies_library", "Movies library"},
      {"tv_library", "TV library"},
      {"ebook_library", "Ebooks library"},
      {"audiobook_library", "Audiobooks library"},
      {"group-download", "Download clients"}
    ]

    for {row, label} <- rows do
      assert has_element?(lv, "#setup-check-#{row}", label)
    end

    row_ids =
      lv
      |> element("#setup-checklist")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li")
      |> LazyHTML.attribute("id")

    assert row_ids == Enum.map(rows, fn {row, _label} -> "setup-check-#{row}" end)
    assert has_element?(lv, "#setup-check-group-download", "connect at least one")
  end

  test "every Test button carries its probe target's id", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    for target <- Cinder.Health.targets() do
      assert has_element?(
               lv,
               "button#test-target-#{target.id}[phx-value-target=#{target.id}]",
               "Test #{target.label}"
             )
    end
  end

  test "a Test event for an id no probe target has changes nothing", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    before = render(lv)

    for forged <- ["nope", %{"x" => 1}] do
      render_hook(lv, "test", %{"target" => forged})
      assert render(lv) == before
    end

    refute has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "a per-service Test button updates that service's badge", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    html = lv |> element("button", "Test TMDB") |> render_click()

    assert html =~ "OK"
  end

  test "a Test button whose probe outlasts the budget reads Timed out and the page answers again",
       %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    # The indexer alone gets the shrunk budget, which `reset_cinder_env` restores. Waited out, it
    # would read OK.
    Application.put_env(:cinder, :health_probe_timeout_ms, %{"indexer" => 200})
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> sleep_ok(5_000) end)
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    assert has_element?(lv, "#test-target-indexer", "Test Indexers")
    lv |> element("#test-target-indexer") |> render_click()
    assert has_element?(lv, "#setup-check-indexer", "Timed out")
    assert has_element?(lv, "#test-reason-indexer.text-error", "Timed out")
    assert has_element?(lv, "#finish-setup[disabled]")

    lv |> element("button", "Test TMDB") |> render_click()
    assert has_element?(lv, "#setup-check-tmdb .hero-check-circle")
  end

  test "native disclosures avoid server events and successful validation resets form state", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")
    assert has_element?(lv, ~s|#setup-form[phx-hook="FormState"][data-form-revision="0"]|)
    assert has_element?(lv, "#settings-group-tmdb[phx-hook=DisclosureState]")
    refute has_element?(lv, "#settings-group-tmdb > summary[phx-click]")

    lv |> element("button", "Test TMDB") |> render_click()
    assert has_element?(lv, ~s|#setup-form[data-form-revision="0"]|)

    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, ~s|#setup-form[data-form-revision="1"]|)
  end

  test "invalid setup preserves safe values and opens, describes, and focuses the field", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    html =
      lv
      |> form("#setup-form", %{
        "prowlarr_url" => "http://typed:9696",
        "movies_min_size" => "wrong",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, "#settings-group-releases[open]")
    assert has_element?(lv, ~s|#prowlarr_url[value="http://typed:9696"]|)
    assert has_element?(lv, ~s|#movies_min_size[value="wrong"][aria-invalid="true"]|)
    assert has_element?(lv, "#movies_min_size-error")
    refute html =~ "must-never-echo"
    flash = lv |> element("#flash-error") |> render()
    refute flash =~ "movies_min_size"
    assert flash =~ "Movies: Min size (GB)"
    assert_push_event(lv, "focus-invalid", %{id: "movies_min_size"})
  end

  test "the wizard surfaces optional notifications without gating Finish", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, ~p"/setup")

    # The SMTP + Discord fields are reachable in the wizard (reused SettingsComponents markup),
    assert html =~ ~s(name="smtp_host")
    assert html =~ ~s(name="discord_webhook_url")
    # and a signpost makes the optional notifications step discoverable rather than silently off.
    assert has_element?(lv, "#setup-notifications-note")
    # It is not part of the required set — no notification service appears in the checklist.
    refute has_element?(lv, "#setup-checklist", "Discord")
  end

  # `validate` is the other caller of Settings.save_form/1, which reaches into the payload's
  # VALUES — String.trim/1 and String.split/2 both raise on a non-binary, past the point where
  # the clause matched and so past the catch-all. First-run-only, but same admin threat model.
  test "a forged validate payload is ignored rather than crashing the wizard", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    prowlarr_before = Cinder.Settings.get("prowlarr_url")

    assert render_hook(lv, "validate", ["forged"])

    for forged <- [%{"forged" => true}, ["x"], 7] do
      assert render_hook(lv, "validate", %{"tv_max_size" => forged})
      assert render_hook(lv, "validate", %{"import_roots" => forged})
      assert render_hook(lv, "validate", %{"prowlarr_url" => forged})
    end

    assert Process.alive?(lv.pid)
    assert Cinder.Settings.get("prowlarr_url") == prowlarr_before
  end

  test "non-admins cannot reach /setup", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
  end

  describe "the Indexers step" do
    test "holds the source select and the indexers table, and reads Add your indexers",
         %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
      {:ok, lv, _html} = live(conn, ~p"/setup")

      assert has_element?(
               lv,
               "#setup-form #settings-group-indexer select#indexer_source[name=indexer_source]"
             )

      assert has_element?(lv, "#setup-form #settings-group-indexer #indexers #indexers-add")
      assert has_element?(lv, "#setup-step-2", "Add your indexers, or connect Prowlarr.")
      assert has_element?(lv, "#settings-group-indexer .setup-section-help", @indexer_help)

      assert has_element?(
               lv,
               "#settings-group-indexer .setup-section-help a",
               "Prowlarr settings guide"
             )
    end

    test "Save & validate stores Built-in with no working indexer, and refuses nothing",
         %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
      stub_all_services_ok()
      {:ok, lv, _html} = live(conn, ~p"/setup")

      validate(lv, "native")

      assert Settings.indexer_source() == "native"
      assert has_element?(lv, ~s|#setup-form[data-form-revision="1"]|)
      refute has_element?(lv, "#flash-error")
      refute has_element?(lv, "#indexer_source-error")
      assert has_element?(lv, "#setup-check-indexer .hero-x-circle")
      assert has_element?(lv, "#setup-check-indexer .text-error", "No indexer added")
      assert has_element?(lv, "#finish-setup[disabled]")
    end
  end

  describe "on Built-in" do
    @now ~U[2026-11-26 12:00:00Z]
    @key "SYNTH-key-setup-1663"

    setup %{conn: conn} do
      ConfigCase.put_env(Native, clock: fn -> @now end)
      block_tests()
      stop_tests_on_exit()
      :ok = TestRunner.subscribe()
      stub_all_services_ok()
      %{conn: log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())}
    end

    test "Test-on-save of the first indexer unlocks Finish, and disabling it locks it again",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup[disabled]")

      add_indexer(lv, "Usenet One")
      assert [%{id: id}] = Indexers.list()
      assert_receive {:test_started, task_pid, ^id}
      # The Test still runs: nothing passes yet.
      render(lv)
      assert has_element?(lv, "#finish-setup[disabled]")

      answer(task_pid, :test_success)
      eventually(fn -> has_element?(lv, "#finish-setup:not([disabled])") end)
      assert has_element?(lv, "#setup-check-indexer .hero-check-circle.text-success")

      lv |> element("#indexer-#{id}-enabled") |> render_click()
      assert has_element?(lv, "#finish-setup[disabled]")
      assert has_element?(lv, "#setup-check-indexer .text-error", "No indexer is enabled")

      render_hook(lv, "finish", %{})
      refute Settings.setup_complete?()
    end

    test "a saved switch to Built-in makes Delete warn about the only working indexer",
         %{conn: conn} do
      %{id: id} = usable!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      refute has_element?(lv, "#indexer-#{id}-delete[data-confirm*='only working indexer']")

      validate(lv, "native")
      assert has_element?(lv, "#indexer-#{id}-delete[data-confirm*='only working indexer']")
    end

    test "a refused save starts no Test and leaves Finish locked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      add_indexer(lv, "Broken", %{"base_url" => "not a url"})
      assert Indexers.list() == []
      assert TestRunner.running() == MapSet.new()
      refute_received {:test_started, _task_pid, _id}
      assert has_element?(lv, "#finish-setup[disabled]")
    end

    test "a Test that ends after a newer edit does not unlock Finish", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      add_indexer(lv, "Usenet One")
      assert [%{id: id}] = Indexers.list()
      assert_receive {:test_started, task_pid, ^id}

      # The edit raises `config_version` while the Test runs, so its answer is dropped.
      lv |> element("#indexer-#{id}-edit") |> render_click()
      save_dialog(lv, %{"base_url" => "https://moved.example"})
      assert [%{config_version: 2}] = Indexers.list()

      answer(task_pid, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:error, :dropped}}
      eventually(fn -> has_element?(lv, "#indexers-notice", "stored nothing") end)
      # The table sent its host notice before it showed that result, so this render comes after
      # the host's recompute.
      render(lv)
      assert has_element?(lv, "#finish-setup[disabled]")
      assert has_element?(lv, "#setup-check-indexer .hero-x-circle")
    end

    test "the Test button's finish unlocks Finish", %{conn: conn} do
      %{id: id} = indexer!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup[disabled]")

      lv |> element("#indexer-#{id}-test") |> render_click()
      assert_receive {:test_started, task_pid, ^id}
      answer(task_pid, :test_success)
      eventually(fn -> has_element?(lv, "#finish-setup:not([disabled])") end)
    end

    test "an edit that disables the indexer locks Finish", %{conn: conn} do
      %{id: id} = usable!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup:not([disabled])")

      lv |> element("#indexer-#{id}-edit") |> render_click()
      save_dialog(lv, %{"enabled" => "false"})
      assert [%{enabled: false}] = Indexers.list()
      assert has_element?(lv, "#finish-setup[disabled]")
    end

    test "deleting the only working indexer locks Finish", %{conn: conn} do
      %{id: id} = usable!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup:not([disabled])")

      lv |> element("#indexer-#{id}-delete") |> render_click()
      assert Indexers.list() == []
      assert has_element?(lv, "#finish-setup[disabled]")
      assert has_element?(lv, "#setup-check-indexer .text-error", "No indexer added")
    end

    test "finish recomputes the gate from the saved indexers before it completes setup",
         %{conn: conn} do
      indexer = usable!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup:not([disabled])")

      # Another tab disables it: no message tells this page.
      {:ok, _row} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)

      lv |> element("#finish-setup") |> render_click()
      refute Settings.setup_complete?()
      assert has_element?(lv, "#finish-setup[disabled]")
      assert has_element?(lv, "#setup-check-indexer .text-error", "No indexer is enabled")
    end

    test "finish completes setup while the gate still passes", %{conn: conn} do
      usable!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      lv |> element("#finish-setup") |> render_click()
      assert Settings.setup_complete?()
    end

    test "an indexer waiting out a limit, with none usable, unlocks Finish in yellow",
         %{conn: conn} do
      indexer!(:newznab, "nzb.example") |> record!({:limit, DateTime.add(@now, 600)})
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#finish-setup:not([disabled])")
      assert has_element?(lv, "#setup-check-indexer .hero-exclamation-triangle.text-warning")
      assert has_element?(lv, "#setup-check-indexer .text-warning", "nzb.example")
    end

    test "a passing indexer beside a failing one unlocks Finish in yellow with the reason",
         %{conn: conn} do
      usable!(:newznab, "ok.example")
      indexer!(:newznab, "fail.example") |> record!(:timeout)
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#finish-setup:not([disabled])")
      assert has_element?(lv, "#setup-check-indexer .hero-exclamation-triangle.text-warning")
      assert has_element?(lv, "#setup-check-indexer .text-warning", "fail.example")
      refute has_element?(lv, "#setup-check-indexer .text-warning", "ok.example")
    end

    test "a never-checked indexer does not pass", %{conn: conn} do
      indexer!(:newznab, "nzb.example")
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#finish-setup[disabled]")
      assert has_element?(lv, "#setup-check-indexer .hero-x-circle")
    end

    test "a Usenet indexer with only the torrent client working keeps Finish locked",
         %{conn: conn} do
      usable!(:newznab, "nzb.example")
      Req.Test.stub(Cinder.SabnzbdStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#setup-check-group-download .hero-check-circle")
      assert has_element?(lv, "#setup-check-indexer .hero-x-circle")
      assert has_element?(lv, "#setup-check-indexer .text-error", @coverage)
      assert has_element?(lv, "#finish-setup[disabled]")
    end

    test "a torrent indexer with only the Usenet client working keeps Finish locked",
         %{conn: conn} do
      # `block_tests/0` maps Newznab alone; with no adapter a Torznab row reads not supported.
      ConfigCase.put_env(:indexer_adapters, %{
        newznab: Cinder.Acquisition.IndexerAdapterMock,
        torznab: Cinder.Acquisition.Indexer.Torznab
      })

      usable!(:torznab, "tz.example")
      Req.Test.stub(Cinder.QBittorrentStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#setup-check-group-download .hero-check-circle")
      assert has_element?(lv, "#setup-check-indexer .text-error", @coverage)
      assert has_element?(lv, "#finish-setup[disabled]")
    end

    test "a Usenet indexer with the Usenet client working unlocks Finish", %{conn: conn} do
      usable!(:newznab, "nzb.example")
      Req.Test.stub(Cinder.QBittorrentStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      refute has_element?(lv, "#setup-check-indexer", @coverage)
      assert has_element?(lv, "#setup-check-indexer .hero-check-circle")
      assert has_element?(lv, "#finish-setup:not([disabled])")
    end

    test "a torrent indexer with only a warning Usenet client keeps Finish locked",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_adapters, %{
        newznab: Cinder.Acquisition.IndexerAdapterMock,
        torznab: Cinder.Acquisition.Indexer.Torznab
      })

      usable!(:torznab, "tz.example")
      stub_sabnzbd_warning()
      Req.Test.stub(Cinder.QBittorrentStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#setup-check-group-download .text-warning")
      assert has_element?(lv, "#setup-check-indexer .text-error", @coverage)
      assert has_element?(lv, "#finish-setup[disabled]")
    end

    test "a Usenet indexer with a warning Usenet client unlocks Finish", %{conn: conn} do
      usable!(:newznab, "nzb.example")
      stub_sabnzbd_warning()
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      refute has_element?(lv, "#setup-check-indexer", @coverage)
      assert has_element?(lv, "#setup-check-indexer .hero-check-circle")
      assert has_element?(lv, "#finish-setup:not([disabled])")
    end

    test "a limit that ends while the page is open locks Finish", %{conn: conn} do
      indexer!(:newznab, "nzb.example") |> record!({:limit, DateTime.add(@now, 600)})
      [%{state: {:limit_backoff, until}}] = IndexerState.list(@now)
      # The table reads its rows again just past the limit's end, from a real timer: the page
      # opens one second before that end.
      ConfigCase.put_env(Native, clock: fn -> DateTime.add(until, -1) end)
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")
      assert has_element?(lv, "#finish-setup:not([disabled])")

      ConfigCase.put_env(Native, clock: fn -> DateTime.add(until, 1) end)
      eventually(fn -> has_element?(lv, "#finish-setup[disabled]") end)
      assert has_element?(lv, "#setup-check-indexer .hero-x-circle")
    end

    test "the protocol check stays silent while no download client works", %{conn: conn} do
      usable!(:newznab, "nzb.example")
      Req.Test.stub(Cinder.QBittorrentStub, &Req.Test.transport_error(&1, :econnrefused))
      Req.Test.stub(Cinder.SabnzbdStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "native")

      assert has_element?(lv, "#setup-check-group-download", "None reachable")
      assert has_element?(lv, "#setup-check-indexer .hero-check-circle")
      refute has_element?(lv, "#setup-check-indexer", @coverage)
      assert has_element?(lv, "#finish-setup[disabled]")
    end
  end

  describe "on Prowlarr" do
    test "a passing probe unlocks Finish with no protocol check", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
      ConfigCase.put_env(Native, clock: fn -> @now end)
      stub_all_services_ok()
      # A Built-in indexer that only the failing Usenet client could take: Built-in's protocol
      # check would fail it.
      usable!(:newznab, "nzb.example")
      Req.Test.stub(Cinder.SabnzbdStub, &Req.Test.transport_error(&1, :econnrefused))
      {:ok, lv, _html} = live(conn, ~p"/setup")
      validate(lv, "prowlarr")

      assert has_element?(lv, "#setup-check-indexer .hero-check-circle")
      refute has_element?(lv, "#setup-check-indexer", @coverage)
      assert has_element?(lv, "#finish-setup:not([disabled])")
    end
  end

  test "a SABnzbd configuration warning shows yellow with its reason in the download row",
       %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
    stub_all_services_ok()

    stub_sabnzbd_warning()

    {:ok, lv, _html} = live(conn, ~p"/setup")
    validate(lv, "prowlarr")

    assert has_element?(lv, "#setup-check-group-download .hero-exclamation-triangle.text-warning")

    assert has_element?(
             lv,
             "#setup-check-group-download .text-warning",
             "Folder name limit is 60"
           )

    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "the SABnzbd Test button shows its warning yellow, in its badge and the download row",
       %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
    stub_all_services_ok()
    {:ok, lv, _html} = live(conn, ~p"/setup")
    validate(lv, "prowlarr")
    assert has_element?(lv, "#setup-check-group-download .hero-check-circle")

    stub_sabnzbd_warning()
    lv |> element("#test-target-usenet") |> render_click()

    assert has_element?(lv, "#test-reason-usenet.text-warning", "Folder name limit is 60")
    assert has_element?(lv, "#setup-check-group-download .hero-exclamation-triangle.text-warning")
    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  # SABnzbd answers its queue and reports a folder name limit too short for Cinder's job names:
  # its check passes with a warning.
  defp stub_sabnzbd_warning do
    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{"config" => %{"misc" => %{"folder_max_length" => 60}}})
      end
    end)
  end

  defp validate(lv, source) do
    lv
    |> form("#setup-form", Map.put(@valid_params_with_books, "indexer_source", source))
    |> render_submit()
  end

  defp usable!(type, host), do: indexer!(type, host) |> record!(:success)

  defp record!(indexer, answer) do
    assert IndexerStatus.record(indexer, answer, @now) in [:written, :unchanged]
    indexer
  end

  # Adds a Newznab indexer through the Add dialog: its form starts with the default API path,
  # priority and enabled box, which a save merges under the typed values.
  defp add_indexer(lv, name, typed \\ %{}) do
    lv |> element("#indexers-add") |> render_click()
    lv |> with_target("#indexers") |> render_click("pick", %{"type" => "newznab"})

    save_dialog(
      lv,
      Map.merge(
        %{
          "name" => name,
          "base_url" => "https://#{String.downcase(name) |> String.replace(" ", "-")}.example"
        },
        typed
      ),
      %{"api_key" => @key}
    )
  end

  # The secrets map always holds a key: an empty map would leave the payload (testing.md).
  defp save_dialog(lv, typed, secrets \\ %{"unused" => ""}) do
    lv
    |> with_target("#indexers")
    |> render_submit("save", %{"indexer" => typed, "secrets" => secrets})
  end

  # Polls until `check` holds, up to 5 s: a runner message reaches the page, the component and the
  # page again in turn.
  defp eventually(check, rounds \\ 250) do
    cond do
      check.() ->
        :ok

      rounds == 0 ->
        flunk("the page never matched")

      true ->
        Process.sleep(20)
        eventually(check, rounds - 1)
    end
  end
end
