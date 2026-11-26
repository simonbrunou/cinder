defmodule CinderWeb.SettingsIndexersTest do
  # The indexers table in the Indexers group of /settings (#1660, #1625 points 1, 3, 11 and 12).
  # The rows read `IndexerState.list/1` with Native's clock pinned, and each Test runs the real
  # `Native.test_indexer/1` through `TestRunner` with the Newznab type on `IndexerAdapterMock`,
  # whose stub blocks until the test answers (`Cinder.TestRunnerHelpers`).
  #
  # Not async: the runner, its supervisor, Native's clock and the adapter map are app-wide, and
  # the LiveView and the Test tasks reach the database through the shared sandbox.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.NewznabFixtures, only: [indexer!: 2, indexer!: 3, undecryptable!: 1]
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, IndexerStatus, TestRunner}
  alias Cinder.{ConfigCase, DefinitionFixtures}
  alias Cinder.Indexers
  alias Cinder.Indexers.Definitions
  alias CinderWeb.IndexersComponent

  @now ~U[2026-11-26 12:00:00Z]

  setup :register_and_log_in_admin
  setup :reset_cinder_env
  setup {Mox, :set_mox_global}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    block_tests()
    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    :ok
  end

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp record!(indexer, answers) do
    for {answer, seconds} <- answers do
      assert IndexerStatus.record(indexer, answer, at(seconds)) in [:written, :unchanged]
    end

    indexer
  end

  defp disable!(indexer) do
    {:ok, row} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)
    row
  end

  defp entry(id), do: Enum.find(IndexerState.list(@now), &(&1.id == id))

  # Polls until `check` holds, up to 5 s: a runner message reaches the page and the test process
  # in no fixed order, so a render right after the test's own copy can come before the page's.
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

  defp click(lv, selector), do: lv |> element(selector) |> render_click()

  # The ids of the table's rows, top to bottom.
  defp row_ids(lv) do
    html = lv |> element("#indexers tbody") |> render()
    for [_match, id] <- Regex.scan(~r/\sid="indexer-(\d+)"/, html), do: String.to_integer(id)
  end

  describe "the group" do
    test "is titled Indexers", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert lv |> element("#settings-group-indexer summary") |> render() =~
               "<span>Indexers</span>"
    end

    test "is titled Indexeurs for a French admin", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      {:ok, admin} = Cinder.Accounts.update_user_locale(admin, %{locale: "fr"})
      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/settings")

      assert lv |> element("#settings-group-indexer summary") |> render() =~
               "<span>Indexeurs</span>"
    end

    test "shows its section help with the Prowlarr link, the only group on /settings that does",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               "#settings-group-indexer .setup-section-help a",
               "Prowlarr settings guide"
             )

      for {group, _label} <- Cinder.Settings.groups(), group != :indexer do
        refute has_element?(lv, "#settings-group-#{group} .setup-section-help"),
               "#{group} shows its setup help on /settings"
      end
    end

    test "places the table after the section help and before the Prowlarr fields",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      html = lv |> element("#settings-group-indexer") |> render()

      [help, table, url] =
        for marker <- ["setup-section-help", ~s(id="indexers"), ~s(id="prowlarr_url")] do
          {position, _length} = :binary.match(html, marker)
          position
        end

      assert help < table and table < url
    end

    test "/setup renders no indexers table", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")
      assert has_element?(lv, "#settings-group-indexer")
      refute has_element?(lv, "#indexers")
    end
  end

  describe "the rows" do
    test "with no configured indexer, says none was added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               "#indexers #indexers-empty",
               "No indexer added. Add one, or import them from Prowlarr."
             )

      refute has_element?(lv, "#indexers table")
    end

    test "list every indexer by priority, then id, with its kind, protocol and state",
         %{conn: conn} do
      first = indexer!(:newznab, "a.example", %{name: "Alpha", priority: 25})
      second = indexer!(:torznab, "b.example", %{name: "Bravo", priority: 25}) |> disable!()
      top = indexer!(:newznab, "c.example", %{name: "Charlie", priority: 10})
      assert first.id < second.id

      {:ok, lv, _html} = live(conn, ~p"/settings")
      html = lv |> element("#indexers tbody") |> render()

      positions =
        for id <- [top.id, first.id, second.id] do
          {position, _length} = :binary.match(html, ~s(id="indexer-#{id}"))
          position
        end

      assert positions == Enum.sort(positions)

      assert has_element?(lv, "#indexer-#{first.id}", "Alpha")
      assert has_element?(lv, "#indexer-#{first.id}", "Newznab")
      assert has_element?(lv, "#indexer-#{first.id}", "Usenet")
      assert has_element?(lv, "#indexer-#{second.id}", "Torznab")
      assert has_element?(lv, "#indexer-#{second.id}", "Torrent")

      assert has_element?(
               lv,
               "#indexer-#{first.id}-detail",
               CinderWeb.IndexerStateText.detail(entry(first.id).state, @now)
             )

      assert has_element?(lv, "#indexer-#{first.id}-detail", "Not checked yet")
      assert has_element?(lv, "#indexer-#{first.id}-badge.badge-warning", "Warning")
      assert has_element?(lv, "#indexer-#{second.id}-badge.badge-ghost", "Disabled")
      refute has_element?(lv, "#indexer-#{second.id}-detail")
    end

    # #1668's definition states, built as `Cinder.HealthTest` builds them: Cardigann rows have no
    # adapter until #1671, so Torznab's module stands in for the map's key.
    test "a Cardigann definition that no longer loads reads red, a held update yellow, neither with a detail",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_adapters, %{
        newznab: IndexerAdapterMock,
        cardigann: Cinder.Acquisition.Indexer.Torznab
      })

      base = DefinitionFixtures.definition()
      DefinitionFixtures.mirror!(base)
      broken = DefinitionFixtures.cardigann!(base)
      :written = IndexerStatus.record(broken, :success, @now)
      :ok = Definitions.store_results([{DefinitionFixtures.blob_sha(base), {:error, :not_utf8}}])
      assert {:definition_no_longer_loads, :not_utf8} = entry(broken.id).state

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{broken.id}-badge.badge-error", "Needs attention")
      assert has_element?(lv, "#indexer-#{broken.id}", "Cardigann")
      refute has_element?(lv, "#indexer-#{broken.id}-detail")

      :ok = Indexers.delete(nil, broken.id)
      second = DefinitionFixtures.definition("tracker", %{"name" => "Second"})
      DefinitionFixtures.mirror!(second)
      held = DefinitionFixtures.cardigann!(second, %{"password" => "hunter2"})
      :written = IndexerStatus.record(held, :success, @now)
      DefinitionFixtures.mirror!(DefinitionFixtures.failing("held"))
      assert {:definition_update_held, :fails, _at} = entry(held.id).state

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{held.id}-badge.badge-warning", "Warning")
      refute has_element?(lv, "#indexer-#{held.id}-detail")
    end

    # Each read patches the kept rows in place, so the new row and the new order have to land
    # where the priority puts them.
    test "the next read puts a row added elsewhere in its place, and follows a new priority",
         %{conn: conn} do
      alpha = indexer!(:newznab, "a.example", %{name: "Alpha", priority: 10})
      charlie = indexer!(:newznab, "c.example", %{name: "Charlie", priority: 30})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert row_ids(lv) == [alpha.id, charlie.id]

      bravo = indexer!(:newznab, "b.example", %{name: "Bravo", priority: 20})
      click(lv, "#indexer-#{alpha.id}-enabled")
      assert row_ids(lv) == [alpha.id, bravo.id, charlie.id]

      {:ok, _row} = Indexers.update(nil, charlie.id, charlie.lock_version, %{priority: 5})
      click(lv, "#indexer-#{alpha.id}-enabled")
      assert row_ids(lv) == [charlie.id, alpha.id, bravo.id]
    end

    test "a usable indexer reads OK in green and its last Test in the household's time",
         %{conn: conn} do
      ConfigCase.put_env(:household_timezone, "Europe/Paris")
      indexer = indexer!(:newznab, "a.example")
      {:written, _} = IndexerStatus.record_test(indexer, :test_success, at(-3_600))
      earlier = indexer!(:newznab, "b.example")
      {:written, _} = IndexerStatus.record_test(earlier, {:http_status, 503}, at(-86_400))

      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexer-#{indexer.id}-badge.badge-success", "OK")
      assert has_element?(lv, "#indexer-#{indexer.id}-last-test", "Last Test: worked at 12:00")

      assert has_element?(
               lv,
               "#indexer-#{earlier.id}-last-test",
               "Last Test: HTTP 503 on Nov 25 at 13:00"
             )
    end

    test "an indexer whose secrets do not decrypt says so and cannot be tested", %{conn: conn} do
      locked = indexer!(:newznab, "locked.example")
      :ok = undecryptable!(locked)
      off = indexer!(:newznab, "off.example") |> disable!()
      off_locked = indexer!(:newznab, "off-locked.example")
      :ok = undecryptable!(off_locked)
      disable!(off_locked)

      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               "#indexer-#{locked.id}-detail",
               "Credentials can't be decrypted: re-enter them"
             )

      assert has_element?(lv, "#indexer-#{locked.id}-badge.badge-error", "Needs attention")
      assert has_element?(lv, "#indexer-#{locked.id}-test[disabled]")
      assert has_element?(lv, "#indexer-#{off_locked.id}-test[disabled]")
      assert has_element?(lv, "#indexer-#{off.id}-test")
      refute has_element?(lv, "#indexer-#{off.id}-test[disabled]")

      # A disabled row reads Disabled, and says why its Test is greyed out when the secrets do
      # not decrypt; a disabled row with good secrets shows no detail.
      assert has_element?(lv, "#indexer-#{off_locked.id}-badge", "Disabled")

      assert has_element?(
               lv,
               "#indexer-#{off_locked.id}-detail",
               "Credentials can't be decrypted: re-enter them"
             )

      refute has_element?(lv, "#indexer-#{off.id}-detail")

      # A forged click on the locked row starts no Test either.
      lv |> with_target("#indexers") |> render_click("test", %{"id" => to_string(locked.id)})
      assert TestRunner.running() == MapSet.new()
    end

    test "the component renders buttons only, none with a name", %{conn: conn} do
      indexer!(:newznab, "a.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexers [role=switch]")
      assert has_element?(lv, "#indexers button[type=button]")
      refute has_element?(lv, "#indexers [name]")
      refute has_element?(lv, "#indexers input")
      refute has_element?(lv, "#indexers button:not([type=button])")
    end

    test "every control is at least 24 px high", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexer-#{indexer.id}-enabled.h-6")
      assert has_element?(lv, "#indexer-#{indexer.id}-test.min-h-6")
      assert has_element?(lv, "#indexer-#{indexer.id}-delete.min-h-6")
    end

    test "Test and Delete use the shared button's neutral and ghost looks", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, ~s(#indexer-#{indexer.id}-test[class~="border-base-content/20"]))
      refute has_element?(lv, "#indexer-#{indexer.id}-test.btn-neutral")
      assert has_element?(lv, "#indexer-#{indexer.id}-delete.btn-ghost.btn-sm")
    end

    test "the table scrolls inside its own box", %{conn: conn} do
      indexer!(:newznab, "a.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexers .w-0.min-w-full.overflow-x-auto > table")
    end

    test "the last Test shows during a limit backoff, under the yellow badge", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      {:written, _} = IndexerStatus.record_test(indexer, :test_success, at(-60))
      record!(indexer, [{{:limit, at(600)}, 0}])

      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexer-#{indexer.id}-badge.badge-warning", "Warning")
      assert has_element?(lv, "#indexer-#{indexer.id}-detail", "Limit reached")
      assert has_element?(lv, "#indexer-#{indexer.id}-last-test", "Last Test: worked at 11:59")
    end
  end

  describe "the enable switch" do
    test "saves at once, says so, and starts no Test", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{indexer.id}-enabled[aria-checked=true]")

      click(lv, "#indexer-#{indexer.id}-enabled")

      assert has_element?(lv, "#indexer-#{indexer.id}-enabled[aria-checked=false]")
      assert has_element?(lv, "#indexers-notice[role=status]", "Alpha disabled.")
      assert [%{enabled: false}] = Indexers.list()

      click(lv, "#indexer-#{indexer.id}-enabled")

      assert has_element?(lv, "#indexer-#{indexer.id}-enabled[aria-checked=true]")
      assert has_element?(lv, "#indexers-notice", "Alpha enabled.")
      assert [%{enabled: true}] = Indexers.list()

      assert TestRunner.running() == MapSet.new()
      refute_received {:test_started, _pid, _id}
      refute_received {TestRunner, :started, _id}
    end

    test "a save the store refuses says it could not be saved", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      # Another tab's edit leaves this page's lock_version stale.
      {:ok, _row} = Indexers.update(nil, indexer.id, indexer.lock_version, %{priority: 30})
      click(lv, "#indexer-#{indexer.id}-enabled")

      assert has_element?(
               lv,
               "#indexers-notice",
               "Alpha could not be saved. Reload the page."
             )

      assert [%{enabled: true}] = Indexers.list()
    end

    test "its notice outlives a re-render of the page", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      Mox.stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{indexer.id}-enabled")
      click(lv, "#test-target-indexer")

      assert has_element?(lv, "#test-target-indexer + .status-badge", "OK")
      assert has_element?(lv, "#indexers-notice", "Alpha disabled.")
    end
  end

  describe "the Test button" do
    test "starts one Test, spins until it finishes, then shows its outcome", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{id}-test")

      assert_receive {:test_started, task_pid, ^id}
      assert task_pid in Task.Supervisor.children(TestRunner.TaskSupervisor)
      assert has_element?(lv, "#indexer-#{id}-test[disabled] .loading-spinner")

      # A second click while the Test runs starts no second Test.
      lv |> with_target("#indexers") |> render_click("test", %{"id" => to_string(id)})
      assert [^task_pid] = Task.Supervisor.children(TestRunner.TaskSupervisor)

      answer(task_pid, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, _}}

      eventually(fn ->
        has_element?(lv, "#indexer-#{id}-last-test", "Last Test: worked at 12:00")
      end)

      refute has_element?(lv, "#indexer-#{id}-test[disabled]")
      refute has_element?(lv, "#indexer-#{id}-test .loading-spinner")
      refute_received {:test_started, _pid, _id}
    end

    test "a fresh page shows a Test still running", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      :ok = TestRunner.start(indexer.id)
      assert_receive {:test_started, task_pid, _id}

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{indexer.id}-test[disabled] .loading-spinner")

      answer(task_pid, :test_success)
      eventually(fn -> not has_element?(lv, "#indexer-#{indexer.id}-test[disabled]") end)
    end

    test "a Test another page starts shows its spinner here too", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      refute has_element?(lv, "#indexer-#{id}-test[disabled]")

      :ok = TestRunner.start(id)
      assert_receive {:test_started, task_pid, ^id}

      eventually(fn -> has_element?(lv, "#indexer-#{id}-test[disabled] .loading-spinner") end)
      answer(task_pid, :test_success)
      eventually(fn -> not has_element?(lv, "#indexer-#{id}-test[disabled]") end)
    end

    test "a disabled indexer can be tested", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example") |> disable!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{indexer.id}-test")

      assert_receive {:test_started, task_pid, id}
      answer(task_pid, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, %{outcome: :success}}}

      eventually(fn ->
        has_element?(lv, "#indexer-#{id}-last-test", "Last Test: worked at 12:00")
      end)
    end

    for {name, answer, text, notice} <- [
          {"a pass", :test_success, "Last Test: worked at 12:00", "Test of Alpha: worked."},
          {"a failure", {:http_status, 503}, "Last Test: HTTP 503 at 12:00",
           "Test of Alpha: HTTP 503."},
          {"a rejected key", :rejected_credentials, "Last Test: API key rejected at 12:00",
           "Test of Alpha: API key rejected."},
          {"a raise", :raise, nil, "Test of Alpha did not finish. Try again."}
        ] do
      test "the Test button is enabled again after #{name}, and the notice says how it ended",
           %{conn: conn} do
        indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
        id = indexer.id
        {:ok, lv, _html} = live(conn, ~p"/settings")

        ExUnit.CaptureLog.capture_log(fn ->
          click(lv, "#indexer-#{id}-test")
          assert has_element?(lv, "#indexers-notice", "Testing Alpha…")
          assert_receive {:test_started, task_pid, ^id}
          answer(task_pid, unquote(answer))
          assert_receive {TestRunner, :finished, ^id, _result}
        end)

        eventually(fn -> not has_element?(lv, "#indexer-#{id}-test[disabled]") end)
        eventually(fn -> has_element?(lv, "#indexers-notice", unquote(notice)) end)

        case unquote(text) do
          nil -> refute has_element?(lv, "#indexer-#{id}-last-test")
          text -> assert has_element?(lv, "#indexer-#{id}-last-test", text)
        end
      end
    end

    test "a runner restart during a Test says the Test did not finish", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      click(lv, "#indexer-#{id}-test")
      assert_receive {:test_started, _task_pid, ^id}

      ref = Process.monitor(TestRunner)
      ExUnit.CaptureLog.capture_log(fn -> Process.exit(Process.whereis(TestRunner), :kill) end)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      assert_receive {TestRunner, :reset}

      eventually(fn ->
        has_element?(lv, "#indexers-notice", "Test of Alpha did not finish. Try again.")
      end)

      refute has_element?(lv, "#indexer-#{id}-test[disabled]")
    end

    # A finish the old runner sent before it died can reach the page after the new runner started
    # another Test, so the page's marks hold a Test that still runs when the reset arrives.
    test "a reset names no Test that still runs", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      :ok = TestRunner.start(id)
      assert_receive {:test_started, task_pid, ^id}
      eventually(fn -> has_element?(lv, "#indexer-#{id}-test[disabled]") end)

      send(lv.pid, {TestRunner, :reset})
      # The first render runs after the page's `handle_info`, which queues the component's
      # `send_update`; the second runs after that update.
      _html = render(lv)
      _html = render(lv)

      refute has_element?(lv, "#indexers-notice", "did not finish")
      assert has_element?(lv, "#indexer-#{id}-test[disabled] .loading-spinner")
      answer(task_pid, :test_success)
    end

    # Another page deleted the indexer, and this page, which no write tells, still lists it.
    test "a Test of an indexer deleted elsewhere says it no longer exists", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      :ok = Indexers.delete(nil, id)

      click(lv, "#indexer-#{id}-test")

      assert_receive {TestRunner, :finished, ^id, {:error, :not_found}}
      eventually(fn -> has_element?(lv, "#indexers-notice", "Alpha no longer exists.") end)
      refute has_element?(lv, "#indexers-notice", "Try again")
      refute has_element?(lv, "#indexers-notice", "Reload")
      refute has_element?(lv, "#indexer-#{id}")
    end

    test "a Test of an indexer whose secrets stopped decrypting says so", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      :ok = undecryptable!(indexer)

      click(lv, "#indexer-#{id}-test")

      assert_receive {TestRunner, :finished, ^id, {:error, :undecryptable_secrets}}

      eventually(fn ->
        has_element?(
          lv,
          "#indexers-notice",
          "Test of Alpha: Credentials can't be decrypted: re-enter them."
        )
      end)
    end

    test "a Test refused for a feature Native lacks says so in the notice", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha", flaresolverr: true})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{id}-test")

      assert_receive {TestRunner, :finished, ^id, {:error, {:not_supported, :flaresolverr}}}

      eventually(fn ->
        has_element?(lv, "#indexers-notice", "Test of Alpha: Not supported: FlareSolverr.")
      end)

      refute_received {:test_started, _pid, _id}
    end

    test "keeps running once the page is gone, and stores its outcome", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{id}-test")
      assert_receive {:test_started, task_pid, ^id}

      # The test's client proxy is linked to the page and exits with it.
      Process.flag(:trap_exit, true)
      ref = Process.monitor(lv.pid)
      GenServer.stop(lv.pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      answer(task_pid, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, _}}
      assert entry(id).last_test == %{outcome: :success, at: @now}
    end

    test "an edit while the Test runs leaves no outcome from it, and the notice says so",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{id}-test")
      assert_receive {:test_started, task_pid, ^id}
      {:ok, _row} = Indexers.update(nil, id, indexer.lock_version, %{api_path: "/api/v2"})
      answer(task_pid, :test_success)

      assert_receive {TestRunner, :finished, ^id, {:error, :dropped}}
      eventually(fn -> not has_element?(lv, "#indexer-#{id}-test[disabled]") end)
      refute has_element?(lv, "#indexer-#{id}-last-test")
      assert entry(id).last_test == nil

      assert has_element?(
               lv,
               "#indexers-notice",
               "Test of Alpha stored nothing: the indexer changed while it ran."
             )
    end

    test "a delete while the Test runs leaves no outcome and the page answers", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      other = indexer!(:newznab, "b.example")
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")

      click(lv, "#indexer-#{id}-test")
      assert_receive {:test_started, task_pid, ^id}
      click(lv, "#indexer-#{id}-delete")
      answer(task_pid, :test_success)

      assert_receive {TestRunner, :finished, ^id, {:error, :dropped}}
      assert Cinder.Repo.get(IndexerStatus, id) == nil
      eventually(fn -> not has_element?(lv, "#indexer-#{id}") end)
      assert has_element?(lv, "#indexer-#{other.id}")
    end
  end

  describe "Delete" do
    @question "Delete Alpha? Its grabs still waiting to be sent are dropped: movies and episodes search again, books wait for you."
    @only "It is your only working indexer, so searches stop until another one works."

    # The whole attribute, matched exactly.
    defp confirm?(lv, id, text),
      do: has_element?(lv, ~s(#indexer-#{id}-delete[data-confirm="#{text}"]))

    test "asks first, deletes through the store and removes the row", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert confirm?(lv, indexer.id, @question)

      click(lv, "#indexer-#{indexer.id}-delete")

      refute has_element?(lv, "#indexer-#{indexer.id}")
      assert has_element?(lv, "#indexers-notice", "Alpha deleted.")
      assert Indexers.list() == []
      assert has_element?(lv, "#indexers-empty")
    end

    # The browser moves focus as the click runs (`JS.focus/1`), so a keyboard user whose
    # focused Delete goes with its row lands on the next row's Delete, else the previous row's,
    # else the group's title.
    test "sends focus to the next row's Delete, else the previous one's, else the group title",
         %{conn: conn} do
      a = indexer!(:newznab, "a.example", %{priority: 10})
      b = indexer!(:newznab, "b.example", %{priority: 20})
      c = indexer!(:newznab, "c.example", %{priority: 30})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      focus_to? = fn id, target ->
        has_element?(lv, ~s(#indexer-#{id}-delete[phx-click*='"to":"#{target}"']))
      end

      assert focus_to?.(a.id, "#indexer-#{b.id}-delete")
      assert focus_to?.(b.id, "#indexer-#{c.id}-delete")
      assert focus_to?.(c.id, "#indexer-#{b.id}-delete")

      click(lv, "#indexer-#{a.id}-delete")
      click(lv, "#indexer-#{c.id}-delete")
      assert focus_to?.(b.id, "#settings-group-indexer > summary")
      assert has_element?(lv, "#settings-group-indexer > summary")
    end

    test "a limit that ends while the page is open reads the rows again, so the warning follows",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Native)
      # A limit lasts at least 60 s from its answer, so Bravo's, answered at 11:59:00, ends at
      # 12:00:00, and the page opens 700 ms before that.
      clock = {__MODULE__, :clock}
      :persistent_term.put(clock, DateTime.add(@now, -700, :millisecond))
      on_exit(fn -> :persistent_term.erase(clock) end)
      ConfigCase.put_env(Native, clock: fn -> :persistent_term.get(clock, @now) end)

      alpha = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, -60}])
      bravo = indexer!(:newznab, "b.example") |> record!([{{:limit, at(0)}, -60}])
      opened = DateTime.add(@now, -700, :millisecond)
      bravo_state = Enum.find(IndexerState.list(opened), &(&1.id == bravo.id)).state
      assert match?({:limit_backoff, until} when until == @now, bravo_state), inspect(bravo_state)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, alpha.id, @question)

      :persistent_term.put(clock, at(1))
      eventually(fn -> confirm?(lv, alpha.id, @question <> " " <> @only) end)
    end

    test "with Built-in saved, warns when it is the only indexer that passes the gate",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Native)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, 0}])
      indexer!(:newznab, "fresh.example")

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question <> " " <> @only)
    end

    test "with Built-in saved, an indexer in a running limit backoff counts as working",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Native)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})
      record!(indexer, [{{:limit, at(600)}, 0}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question <> " " <> @only)
    end

    test "with a second indexer that passes the gate, does not warn", %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Native)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, 0}])
      indexer!(:newznab, "b.example") |> record!([{:success, 0}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question)
    end

    test "an indexer that does not pass the gate gets no warning", %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Native)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"})

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question)
    end

    test "a source saved elsewhere while the page is open reaches the warning on the next read",
         %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Cinder.Acquisition.IndexerSource.Prowlarr)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, 0}])
      other = indexer!(:newznab, "b.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question)

      # What a save of the source does (`Cinder.Settings.Overlay`), then an action that reads
      # the rows again.
      Application.put_env(:cinder, :indexer_source, Native)
      click(lv, "#indexer-#{other.id}-enabled")

      assert confirm?(lv, indexer.id, @question <> " " <> @only)
    end

    test "with another indexer source saved, does not warn", %{conn: conn} do
      ConfigCase.put_env(:indexer_source, Cinder.Acquisition.IndexerSource.Prowlarr)
      indexer = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, 0}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, indexer.id, @question)
    end

    # `IndexerState.passes_gate?/1` reads the whole list, so with one enabled indexer at a time
    # it answers for that indexer alone, which the component's per-row check must match.
    test "the per-row gate check matches IndexerState.passes_gate?/1 in every state" do
      cases = [
        usable: &record!(&1, [{:success, 0}]),
        limit_backoff: &record!(&1, [{{:limit, at(600)}, 0}]),
        limit_ended: &record!(&1, [{:success, -7_200}, {{:limit, nil}, -3_600}]),
        failure_backoff: &record!(&1, [{:success, -60}, {:timeout, 0}]),
        retry_due: &record!(&1, [{:success, -600}, {:timeout, -300}]),
        rejected: &record!(&1, [{:success, -60}, {:rejected_credentials, 0}]),
        not_supported: fn indexer ->
          record!(indexer, [{:success, 0}])

          {:ok, _row} =
            Indexers.update(nil, indexer.id, indexer.lock_version, %{flaresolverr: true})
        end,
        never_checked: & &1,
        disabled: &(&1 |> record!([{:success, 0}]) |> disable!()),
        undecryptable: fn indexer ->
          record!(indexer, [{:success, 0}])
          undecryptable!(indexer)
        end
      ]

      answers =
        for {name, seed} <- cases do
          indexer = indexer!(:newznab, "#{name}.example")
          seed.(indexer)
          row = entry(indexer.id)
          gate = IndexerState.passes_gate?(@now)
          answer = {name, IndexersComponent.passes_gate?(row), gate, row.state}
          :ok = Indexers.delete(nil, indexer.id)
          answer
        end

      for {name, row_check, gate, _state} <- answers,
          do: assert(row_check == gate, "#{name}")

      gates =
        Map.new(answers, fn {name, row_check, gate, state} -> {name, {row_check, gate, state}} end)

      assert {true, true, {:usable, _at}} = gates.usable
      assert {true, true, {:limit_backoff, _until}} = gates.limit_backoff
      assert {false, false, :never_checked} = gates.never_checked
      assert {false, false, {:not_supported, :flaresolverr}} = gates.not_supported
    end
  end

  describe "forged events" do
    test "an id that is no integer or names no row changes nothing", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example")
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for event <- ~w(toggle test delete), id <- ["abc", "#{indexer.id}x", "999999", 7] do
        lv |> with_target("#indexers") |> render_click(event, %{"id" => id})
      end

      lv |> with_target("#indexers") |> render_click("toggle", %{})
      assert [%{enabled: true}] = Indexers.list()
      assert TestRunner.running() == MapSet.new()
      assert has_element?(lv, "#indexer-#{indexer.id}")
    end

    test "the page still ignores a message it does not know", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      send(lv.pid, {:something, :else})
      send(lv.pid, {TestRunner, :unknown})
      assert has_element?(lv, "#indexers")
    end
  end
end
