defmodule CinderWeb.SettingsDefinitionsLineTest do
  # The definitions line under the indexers table of /settings (#1676, #1625 point 8): the
  # loaded set with Update now, and each set state's badge or alert. Definitions come from
  # `Cinder.DefinitionFixtures`; the Updater runs under the test's supervisor with the source mock.
  #
  # Not async: the source mock is global, the Updater is a named process, and Native's clock is
  # app-wide.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.DefinitionFixtures
  import Mox

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.ConfigCase
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Set, SourceMock, StoredSet, Updater, UpdateRun}
  alias Cinder.Indexers.Definitions.Set.Versions
  alias Cinder.Repo
  alias Cinder.Test.DefinitionsZip

  @now ~U[2026-11-26 12:00:00Z]
  @commit "56b20b19" <> String.duplicate("0", 32)
  @later String.duplicate("b", 40)

  # The boot run of "Update now" fails and logs a warning; keep it out of the suite's output.
  @moduletag :capture_log

  setup :register_and_log_in_admin
  setup :reset_cinder_env
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :persistent_term.erase({Updater, :status})
    on_exit(fn -> :persistent_term.erase({Updater, :status}) end)
    :ok
  end

  defp answer(commit, files, min \\ 11) do
    %Set{
      commit: commit,
      versions: %Versions{
        min: min,
        max: 12,
        values: %{"MIN_VERSION" => "#{min}", "MAX_VERSION" => "12"}
      },
      files: files
    }
  end

  defp three do
    for id <- ["a", "b", "c"], do: file("v11", "#{id}.yml", definition(id))
  end

  # A stored set of three definitions at `@commit`: the first answer under 100 names is refused,
  # then accepted.
  defp three_loaded! do
    assert {:error, {:first_too_small, _}} =
             Definitions.apply_set(answer(@commit, three()), check: &check/1)

    :ok = Definitions.accept_smaller_set(@commit)
    assert {:ok, {:loaded, _}} = Definitions.apply_set(answer(@commit, three()), check: &check/1)
    Repo.update_all(StoredSet, set: [loaded_at: ~U[2026-11-26 10:00:00Z]])
    :ok
  end

  defp run!(fields) do
    Repo.insert!(
      struct(
        UpdateRun,
        Keyword.merge(
          [id: UpdateRun.id(), started_at: @now, ended_at: @now, outcome: :unchanged],
          fields
        )
      ),
      on_conflict: :replace_all,
      conflict_target: :id
    )
  end

  test "the loaded set's count, commit and last check, with Update now", %{conn: conn} do
    three_loaded!()
    run!(last_success_at: ~U[2026-11-26 11:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             "#indexer-definitions-loaded",
             "Indexer definitions: 3 loaded at 56b20b19, checked 11:00"
           )

    assert has_element?(
             lv,
             "#indexer-definitions-loaded #indexer-definitions-update",
             "Update now"
           )

    refute has_element?(lv, "#indexer-definitions-failing")
  end

  describe "update failing" do
    for {hours, shown?} <- [{73, true}, {71, false}] do
      @hours hours
      @shown shown?

      test "a last success #{hours} hours old #{if shown?, do: "shows", else: "does not show"} the badge",
           %{conn: conn} do
        three_loaded!()
        success = DateTime.add(@now, -@hours * 3600)

        run!(
          outcome: :failed,
          error: UpdateRun.encode_error({:failed, :timeout}),
          last_success_at: success,
          first_failure_at: DateTime.add(success, 3600)
        )

        {:ok, lv, _html} = live(conn, ~p"/settings")

        assert has_element?(lv, "#indexer-definitions-failing", "Update failing since") == @shown

        assert has_element?(lv, "#indexer-definitions-error", "GitHub did not answer in time") ==
                 @shown
      end
    end
  end

  test "a shrunk answer shows its alert, and Accept smaller set accepts that answer",
       %{conn: conn} do
    assert {:ok, {:loaded, _}} = apply_files([])
    files = for i <- 1..50, do: file("v11", "f-#{i}.yml", definition("f-#{i}"))
    assert {:error, {:shrank, _}} = Definitions.apply_set(answer(@later, files), check: &check/1)

    {:ok, lv, _html} = live(conn, ~p"/settings")
    assert has_element?(lv, "#indexer-definitions-smaller", "The upstream answer shrank by 50%.")

    lv |> element("#indexer-definitions-accept-smaller") |> render_click()
    assert Repo.get!(StoredSet, 1).accepted_commit == @later
  end

  test "a MIN_VERSION above the engine's shows the red alert", %{conn: conn} do
    assert {:error, {:cinder_too_old, _}} =
             Definitions.apply_set(answer(@later, three(), 13), check: &check/1)

    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             "#indexer-definitions-too-old.alert-error",
             "Cinder is too old for current definitions"
           )
  end

  test "before any load: the not-loaded alert, the last fetch error and Retry", %{conn: conn} do
    run!(outcome: :failed, error: UpdateRun.encode_error({:failed, {:http_status, 503}}))
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             "#indexer-definitions-not-loaded",
             "Indexer definitions not loaded yet"
           )

    assert has_element?(lv, "#indexer-definitions-error", "GitHub answered HTTP 503")

    assert has_element?(
             lv,
             "#indexer-definitions-not-loaded #indexer-definitions-update",
             "Retry"
           )
  end

  describe "Update now" do
    # The boot run fails; each later master_commit call reports to the test and waits for
    # `:release`.
    setup do
      test_pid = self()
      stub(SourceMock, :master_commit, fn -> {:error, :timeout} end)
      :ok = Updater.subscribe()

      start_supervised!(
        {Updater,
         [check: &check/1, clock: fn -> @now end, schedule: fn _delay, _message -> make_ref() end]}
      )

      assert_receive {:definitions_update, {:failed, :timeout}}, 10_000

      stub(SourceMock, :master_commit, fn ->
        send(test_pid, {:master_commit, self()})

        receive do
          :release -> {:ok, @later}
        end
      end)

      fillers =
        for i <- 1..100, do: {"definitions/v11/filler-#{i}.yml", definition("filler-#{i}")}

      zip =
        DefinitionsZip.codeload(@later, [
          {"VERSIONS", "MIN_VERSION=11\nMAX_VERSION=12\n"} | fillers
        ])

      stub(SourceMock, :download, fn @later -> {:ok, zip} end)
      :ok
    end

    test "runs once while a click waits, and the line shows the new commit at the end",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-definitions-update") |> render_click()
      assert_receive {:master_commit, run}, 10_000
      assert has_element?(lv, "#indexer-definitions-update[disabled] .loading-spinner")

      lv |> with_target("#indexers") |> render_click("update_definitions", %{})
      refute_receive {:master_commit, _pid}, 200

      send(run, :release)
      assert_receive {:definitions_update, :applied}, 10_000

      eventually(fn ->
        has_element?(lv, "#indexer-definitions-loaded", "100 loaded at bbbbbbbb")
      end)

      refute has_element?(lv, "#indexer-definitions-update[disabled]")
      assert has_element?(lv, "#indexer-definitions-notice", "Indexer definitions updated.")
    end
  end

  # Polls until `check` holds, up to 5 s: the host forwards the run's end with `send_update/3`,
  # which the page handles after the broadcast that reached the test.
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
