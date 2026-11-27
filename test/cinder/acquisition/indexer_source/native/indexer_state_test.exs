defmodule Cinder.Acquisition.IndexerSource.Native.IndexerStateTest do
  # The per-indexer state function, the source's `health/0` and the gate (#1657, #1619 points 6,
  # 13 and 14, #1623 points 1 and 9). Each state is reached through the real status transitions
  # (`IndexerStatus.record/3`), never by writing a row by hand. Every expected time is a literal.
  #
  # Not async: Native's clock and the adapter map are global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, IndexerStatus}
  alias Cinder.ConfigCase
  alias Cinder.DefinitionFixtures
  alias Cinder.Indexers
  alias Cinder.Indexers.Definitions

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp record!(indexer, answers) do
    for {answer, seconds} <- answers do
      assert IndexerStatus.record(indexer, answer, at(seconds)) in [:written, :unchanged]
    end

    indexer
  end

  defp state(indexer, now \\ @now),
    do: Enum.find(IndexerState.list(now), &(&1.id == indexer.id)).state

  defp disable!(indexer) do
    {:ok, row} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)
    row
  end

  describe "needs_admin?/1" do
    # Rules 2 to 5 need the admin; `Cinder.Health` shows them red.
    test "is true for each state of rules 2 to 5 and false for every other state" do
      for {state, expected} <- [
            {:disabled, false},
            {:undecryptable, true},
            {{:not_supported, :flaresolverr}, true},
            {{:definition_no_longer_loads, :not_utf8}, true},
            {{:credentials_rejected, {:code, 101}}, true},
            {{:limit_backoff, @now}, false},
            {{:failure_backoff, @now, :timeout, 1}, false},
            {{:retry_due, @now, :timeout, 1}, false},
            {{:usable, @now}, false},
            {{:definition_update_held, :hosts, @now}, false},
            {{:removed_upstream, @now}, false},
            {{:replaced_by, "successor.yml", @now}, false},
            {:never_checked, false}
          ],
          IndexerState.needs_admin?(state) != expected,
          do: flunk("#{inspect(state)} is not #{expected}")
    end
  end

  describe "list/1" do
    test "lists every configured indexer, disabled and undecryptable included, as plain maps" do
      usenet = indexer!(:newznab, "nzb.example", %{priority: 1})
      torrent = indexer!(:torznab, "tracker.example", %{priority: 2})
      off = indexer!(:newznab, "off.example", %{priority: 3}) |> disable!()
      locked = indexer!(:newznab, "locked.example", %{priority: 4})
      :ok = undecryptable!(locked)

      assert IndexerState.list(@now) == [
               %{
                 id: usenet.id,
                 name: "newznab nzb.example",
                 type: :newznab,
                 protocol: :usenet,
                 enabled: true,
                 state: :never_checked,
                 last_test: nil
               },
               %{
                 id: torrent.id,
                 name: "torznab tracker.example",
                 type: :torznab,
                 protocol: :torrent,
                 enabled: true,
                 state: :never_checked,
                 last_test: nil
               },
               %{
                 id: off.id,
                 name: "newznab off.example",
                 type: :newznab,
                 protocol: :usenet,
                 enabled: false,
                 state: :disabled,
                 last_test: nil
               },
               %{
                 id: locked.id,
                 name: "newznab locked.example",
                 type: :newznab,
                 protocol: :usenet,
                 enabled: true,
                 state: :undecryptable,
                 last_test: nil
               }
             ]
    end

    test "each entry carries the last Test's outcome and time" do
      indexer = indexer!(:newznab, "nzb.example")
      {:written, _} = IndexerStatus.record_test(indexer, {:http_status, 404}, at(-60))

      assert [%{last_test: %{outcome: {:http_status, 404}, at: ~U[2026-11-26 11:59:00Z]}}] =
               IndexerState.list(@now)
    end

    test "a success with no failure since reads usable, with the time of that success" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:success, -120}])
      assert state(indexer) == {:usable, ~U[2026-11-26 11:58:00Z]}
    end

    test "a running failure backoff reads its end, its last failure and the failures in a row" do
      indexer =
        indexer!(:newznab, "nzb.example")
        |> record!([{:timeout, 0}, {:timeout, 0}, {{:http_status, 410}, 0}])

      assert state(indexer) ==
               {:failure_backoff, ~U[2026-11-26 12:15:00Z], {:http_status, 410}, 3}
    end

    test "a failure backoff that has ended reads retry due until the next answer" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:success, -600}, {:dns, 0}])

      assert state(indexer, at(59)) == {:failure_backoff, ~U[2026-11-26 12:01:00Z], :dns, 1}
      assert state(indexer, at(60)) == {:retry_due, ~U[2026-11-26 12:01:00Z], :dns, 1}
    end

    test "a running limit backoff reads its end" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{{:limit, at(5_400)}, 0}])
      assert state(indexer) == {:limit_backoff, ~U[2026-11-26 13:30:00Z]}
    end

    test "an ended limit with no success after it reads retry due, a success before it or not" do
      used = indexer!(:newznab, "used.example") |> record!([{:success, -60}, {{:limit, nil}, 0}])
      fresh = indexer!(:newznab, "fresh.example") |> record!([{{:limit, nil}, 0}])

      assert state(used, at(3_599)) == {:limit_backoff, ~U[2026-11-26 13:00:00Z]}
      assert state(used, at(3_600)) == {:retry_due, ~U[2026-11-26 13:00:00Z], :limit, 0}
      assert state(fresh, at(3_600)) == {:retry_due, ~U[2026-11-26 13:00:00Z], :limit, 0}
    end

    test "a limit stamped the same second as a success reads retry due once it ends" do
      indexer =
        indexer!(:newznab, "nzb.example") |> record!([{:success, 0}, {{:limit, nil}, 0}])

      assert state(indexer, at(3_600)) == {:retry_due, ~U[2026-11-26 13:00:00Z], :limit, 0}
    end

    test "a success during a limit reads usable once the limit ends" do
      indexer =
        indexer!(:newznab, "nzb.example") |> record!([{{:limit, nil}, -60}, {:success, 0}])

      assert state(indexer, at(3_539)) == {:limit_backoff, ~U[2026-11-26 12:59:00Z]}
      assert state(indexer, at(3_540)) == {:usable, @now}
    end

    test "a limit kept across a config_version rise reads retry due once it ends" do
      indexer =
        indexer!(:newznab, "nzb.example") |> record!([{:success, -120}, {{:limit, nil}, -60}])

      {:ok, edited} = Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/v2"})

      assert state(edited, at(3_540)) == {:retry_due, ~U[2026-11-26 12:59:00Z], :limit, 0}
    end

    test "rejected credentials read who rejected them" do
      for {answer, by} <- [
            {{:rejected_credentials, {:code, 101}}, {:code, 101}},
            {{:rejected_credentials, {:http_status, 401}}, {:http_status, 401}},
            {{:rejected_credentials, {:login_rejected, :post}}, {:login_rejected, :post}},
            {{:rejected_credentials, {:login_rejected, :get}}, {:login_rejected, :get}},
            {{:rejected_credentials, {:login_rejected, :form}}, {:login_rejected, :form}},
            {{:rejected_credentials, {:login_rejected, :cookie}}, {:login_rejected, :cookie}},
            {:indexer_auth_failed, nil}
          ] do
        indexer =
          indexer!(:newznab, "nzb#{System.unique_integer([:positive])}.example")
          |> record!([{answer, 0}])

        assert {answer, state(indexer)} == {answer, {:credentials_rejected, by}}
      end
    end

    test "a type with no adapter and a FlareSolverr toggle read not supported" do
      flare = indexer!(:torznab, "flare.example", %{flaresolverr: true})
      torrent = indexer!(:torznab, "tracker.example")
      ConfigCase.put_env(:indexer_adapters, %{newznab: Cinder.Acquisition.Indexer.Newznab})

      assert state(torrent) == {:not_supported, :torznab}
      assert state(flare) == {:not_supported, :torznab}

      ConfigCase.put_env(:indexer_adapters, %{
        newznab: Cinder.Acquisition.Indexer.Newznab,
        torznab: Cinder.Acquisition.Indexer.Torznab
      })

      assert state(flare) == {:not_supported, :flaresolverr}
      assert state(torrent) == :never_checked
    end

    test "a success after a failure ends the backoff and reads usable" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:timeout, -30}, {:success, 0}])
      assert state(indexer) == {:usable, @now}
    end

    test "a config_version rise after failures reads never checked" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:success, -60}, {:timeout, 0}])
      {:ok, edited} = Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/v2"})

      assert state(edited) == :never_checked
    end

    test "rejected credentials, then a passing Test, read usable" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:rejected_credentials, -60}])
      {:written, _} = IndexerStatus.record_test(indexer, :test_success, @now)

      assert state(indexer) == {:usable, @now}
    end
  end

  describe "list/1 precedence: red wins over a wait, disabled over everything" do
    test "rejected credentials win over a running limit and a running failure backoff" do
      limited =
        indexer!(:newznab, "limit.example")
        |> record!([{{:limit, at(600)}, 0}, {:rejected_credentials, 0}])

      failing =
        indexer!(:newznab, "fail.example")
        |> record!([{:timeout, 0}, {{:rejected_credentials, {:code, 100}}, 0}])

      assert state(limited) == {:credentials_rejected, nil}
      assert state(failing) == {:credentials_rejected, {:code, 100}}
    end

    test "not supported wins over rejected credentials and a backoff" do
      indexer =
        indexer!(:torznab, "flare.example", %{flaresolverr: true})
        |> record!([{:timeout, 0}, {:rejected_credentials, 0}])

      assert state(indexer) == {:not_supported, :flaresolverr}
    end

    test "undecryptable wins over not supported and rejected credentials" do
      indexer =
        indexer!(:torznab, "flare.example", %{flaresolverr: true})
        |> record!([{:rejected_credentials, 0}])

      :ok = undecryptable!(indexer)
      assert state(indexer) == :undecryptable
    end

    test "disabled wins over undecryptable" do
      indexer = indexer!(:newznab, "nzb.example") |> record!([{:rejected_credentials, 0}])
      :ok = undecryptable!(indexer)
      off = disable!(indexer)

      assert state(off) == :disabled
    end

    test "a limit backoff wins over a failure that came during it" do
      indexer =
        indexer!(:newznab, "nzb.example") |> record!([{{:limit, at(600)}, 0}, {:timeout, 0}])

      assert state(indexer) == {:limit_backoff, ~U[2026-11-26 12:10:00Z]}
    end
  end

  # Cardigann rows' definition codes (#1668). Only the adapter map's key is read here.
  describe "list/1: Cardigann definition codes" do
    setup do
      ConfigCase.put_env(:indexer_adapters, %{
        newznab: Cinder.Acquisition.Indexer.Newznab,
        torznab: Cinder.Acquisition.Indexer.Torznab,
        cardigann: Cinder.Acquisition.Indexer.Cardigann
      })

      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      :ok
    end

    defp cardigann!(secrets \\ %{"password" => "hunter2"}),
      do: DefinitionFixtures.cardigann!(DefinitionFixtures.definition(), secrets)

    test "a running copy that reads not supported is red, with its first feature" do
      unsupported = DefinitionFixtures.definition("tracker-ns")
      DefinitionFixtures.mirror!(unsupported)
      row = DefinitionFixtures.cardigann!(unsupported) |> record!([{:success, 0}])

      assert state(row) == {:not_supported, :html_search}
      refute IndexerState.usable?(%{state: state(row)})
    end

    test "a running copy that no longer loads is red and not usable" do
      row = cardigann!() |> record!([{:success, 0}])

      :ok =
        Definitions.store_results([
          {DefinitionFixtures.blob_sha(DefinitionFixtures.definition()), {:error, :not_utf8}}
        ])

      assert state(row) == {:definition_no_longer_loads, :not_utf8}
      refute IndexerState.passes_gate?(@now)
    end

    test "a held update reads held with its reason, keeps the last success and stays usable" do
      for {label, candidate, more, reason} <- [
            {"hosts",
             DefinitionFixtures.definition("tracker", %{"description" => "https://new.invalid/"}),
             [], :hosts},
            {"certificates",
             DefinitionFixtures.definition("tracker", %{"certificates" => ["AB"]}), [],
             :certificates},
            {"removed credential",
             DefinitionFixtures.definition("tracker", %{
               "settings" =>
                 Enum.reject(DefinitionFixtures.settings(), &(&1["name"] == "password"))
             }), [], :removed_credential},
            {"retyped credential",
             DefinitionFixtures.definition("tracker", %{
               "settings" =>
                 Enum.map(
                   DefinitionFixtures.settings(),
                   &if(&1["name"] == "password", do: %{&1 | "type" => "text"}, else: &1)
                 )
             }), [], :retyped_credential},
            {"fails", DefinitionFixtures.failing("held"), [], :fails},
            {"not supported", DefinitionFixtures.definition("tracker-ns"), [],
             {:not_supported, :html_search}},
            {"newer", DefinitionFixtures.definition(),
             [{"v13", "tracker.yml", DefinitionFixtures.definition("v13")}],
             {:needs_newer_cinder, 13}}
          ] do
        DefinitionFixtures.mirror!(DefinitionFixtures.definition())
        row = cardigann!() |> record!([{:success, -60}])
        DefinitionFixtures.mirror!(candidate, more)

        assert {label, state(row)} ==
                 {label, {:definition_update_held, reason, ~U[2026-11-26 11:59:00Z]}}

        assert IndexerState.usable?(%{state: state(row)})
        :ok = Indexers.delete(nil, row.id)
      end
    end

    test "a lone held indexer with a success passes the gate and leaves health at ok" do
      row = cardigann!() |> record!([{:success, 0}])
      DefinitionFixtures.mirror!(DefinitionFixtures.failing("held"))

      assert {:definition_update_held, :fails, _at} = state(row)
      assert IndexerState.passes_gate?(@now)
      assert Native.health() == :ok
    end

    # The gate newly accepts the three definition states: each path into one, with the gate
    # asserted after it, and the config_version rises that end the last success.
    test "each path into a definition state passes the gate; an edit and an Accept end it" do
      base = DefinitionFixtures.definition()

      hosted =
        DefinitionFixtures.definition("tracker", %{"description" => "https://new.invalid/"})

      # An apply that holds an update.
      row = cardigann!() |> record!([{:success, 0}])
      DefinitionFixtures.mirror!(hosted)
      assert {:definition_update_held, :hosts, @now} = state(row)
      assert IndexerState.passes_gate?(@now)

      # An Accept raises config_version: no success under the new copy yet.
      :ok = Definitions.accept(row.id, DefinitionFixtures.blob_sha(hosted), nil)
      assert state(row) == :never_checked
      refute IndexerState.passes_gate?(@now)
      :ok = Indexers.delete(nil, row.id)

      # A re-check that holds an update: the mirror's copy had no result, then fails.
      DefinitionFixtures.mirror!(base)
      row = cardigann!() |> record!([{:success, 0}])
      unchecked = DefinitionFixtures.definition("tracker", %{"name" => "Unchecked"})

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} =
          DefinitionFixtures.apply_files([{"v11", "tracker.yml", unchecked}],
            check: fn _bytes -> Process.sleep(:infinity) end,
            timeout_ms: 50
          )
      end)

      assert state(row) == {:usable, @now}

      :ok =
        Definitions.store_results([{DefinitionFixtures.blob_sha(unchecked), {:error, :not_utf8}}])

      assert {:definition_update_held, :fails, @now} = state(row)
      assert IndexerState.passes_gate?(@now)

      # An edit that raises config_version ends the last success, so the hold no longer passes.
      fresh = Repo.get!(Cinder.Indexers.ConfiguredIndexer, row.id)

      {:ok, _} =
        Indexers.update(nil, row.id, fresh.lock_version, %{settings: %{"sort" => "size"}})

      assert state(row) == :never_checked
      refute IndexerState.passes_gate?(@now)
      :ok = Indexers.delete(nil, row.id)

      # Removed upstream, then replaced by, through applies.
      DefinitionFixtures.mirror!(base)
      row = cardigann!() |> record!([{:success, 0}])
      {:ok, _} = DefinitionFixtures.apply_files([])
      assert state(row) == {:removed_upstream, @now}
      assert IndexerState.passes_gate?(@now)

      successor = DefinitionFixtures.definition("successor", %{"replaces" => ["tracker"]})
      {:ok, _} = DefinitionFixtures.apply_files([{"v11", "successor.yml", successor}])
      assert state(row) == {:replaced_by, "successor.yml", @now}
      assert IndexerState.passes_gate?(@now)
    end

    test "a first success after a definition state exists reads that state and passes the gate" do
      base = DefinitionFixtures.definition()

      hosted =
        DefinitionFixtures.definition("tracker", %{"description" => "https://new.invalid/"})

      row = cardigann!()
      DefinitionFixtures.mirror!(hosted)
      assert state(row) == :never_checked
      refute IndexerState.passes_gate?(@now)
      record!(row, [{:success, 0}])
      assert state(row) == {:definition_update_held, :hosts, @now}
      assert IndexerState.passes_gate?(@now)
      :ok = Indexers.delete(nil, row.id)

      DefinitionFixtures.mirror!(base)
      row = cardigann!()
      {:ok, _} = DefinitionFixtures.apply_files([])
      assert state(row) == :never_checked
      refute IndexerState.passes_gate?(@now)
      record!(row, [{:success, 0}])
      assert state(row) == {:removed_upstream, @now}
      assert IndexerState.passes_gate?(@now)
      :ok = Indexers.delete(nil, row.id)

      DefinitionFixtures.mirror!(base)
      row = cardigann!()
      successor = DefinitionFixtures.definition("successor", %{"replaces" => ["tracker"]})
      {:ok, _} = DefinitionFixtures.apply_files([{"v11", "successor.yml", successor}])
      assert state(row) == :never_checked
      refute IndexerState.passes_gate?(@now)
      record!(row, [{:success, 0}])
      assert state(row) == {:replaced_by, "successor.yml", @now}
      assert IndexerState.passes_gate?(@now)
    end

    test "a held indexer never checked, or in a backoff, reads that state and is not usable" do
      fresh = cardigann!()
      failing = cardigann!() |> record!([{:timeout, 0}])
      DefinitionFixtures.mirror!(DefinitionFixtures.failing("held"))

      assert state(fresh) == :never_checked
      assert {:failure_backoff, _until, :timeout, 1} = state(failing)
    end

    test "removed upstream and replaced by keep the last success and stay usable" do
      removed = cardigann!() |> record!([{:success, 0}])
      replacer = DefinitionFixtures.definition("successor", %{"replaces" => ["tracker"]})

      assert {:ok, _} = DefinitionFixtures.apply_files([])
      assert state(removed) == {:removed_upstream, @now}
      assert IndexerState.usable?(%{state: state(removed)})

      assert {:ok, _} = DefinitionFixtures.apply_files([{"v11", "successor.yml", replacer}])
      assert state(removed) == {:replaced_by, "successor.yml", @now}
      assert IndexerState.usable?(%{state: state(removed)})
    end

    test "red outranks a held update" do
      row = cardigann!() |> record!([{:success, 0}])
      DefinitionFixtures.mirror!(DefinitionFixtures.failing("held"))
      record!(row, [{:rejected_credentials, 0}])
      assert state(row) == {:credentials_rejected, nil}

      :ok =
        Definitions.store_results([
          {DefinitionFixtures.blob_sha(DefinitionFixtures.definition()), {:error, :not_utf8}}
        ])

      assert Definitions.indexer_codes() == %{row.id => {:no_longer_loads, :not_utf8}}
      assert state(row) == {:definition_no_longer_loads, :not_utf8}
    end

    test "an undecryptable indexer reads undecryptable; its hold is a code of its own" do
      row = cardigann!()
      :ok = DefinitionFixtures.undecryptable!(row)
      DefinitionFixtures.mirror!(DefinitionFixtures.definition("tracker", %{"name" => "Renamed"}))

      assert state(row) == :undecryptable
      assert Definitions.indexer_codes() == %{row.id => {:held, :undecryptable}}
    end

    test "under the default adapter map a Cardigann row reads not supported: Cardigann" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: Cinder.Acquisition.Indexer.Newznab})
      row = cardigann!() |> record!([{:success, 0}])
      DefinitionFixtures.mirror!(DefinitionFixtures.failing("held"))

      assert state(row) == {:not_supported, :cardigann}
    end

    test "a type with no adapter wins over a red definition code" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: Cinder.Acquisition.Indexer.Newznab})
      unsupported = DefinitionFixtures.definition("tracker-ns")
      DefinitionFixtures.mirror!(unsupported)
      row = DefinitionFixtures.cardigann!(unsupported) |> record!([{:success, 0}])

      assert Definitions.indexer_codes() == %{row.id => {:not_supported, :html_search}}
      assert state(row) == {:not_supported, :cardigann}
    end
  end

  describe "Native.health/0" do
    test "with no configured indexer: no indexer added" do
      assert Native.health() == {:error, :no_indexer_added}
    end

    test "with none enabled: no indexer is enabled" do
      indexer!(:newznab, "nzb.example") |> record!([{:success, 0}]) |> disable!()
      assert Native.health() == {:error, :no_indexer_enabled}
    end

    test "with no enabled indexer usable: an error listing each one with its state" do
      a = indexer!(:newznab, "a.example", %{priority: 1})
      b = indexer!(:newznab, "b.example", %{priority: 2}) |> record!([{:timeout, 0}])
      indexer!(:newznab, "off.example", %{priority: 3}) |> record!([{:success, 0}]) |> disable!()

      assert Native.health() ==
               {:error,
                {:native_indexers,
                 [
                   %{name: a.name, state: :never_checked},
                   %{name: b.name, state: {:failure_backoff, at(60), :timeout, 1}}
                 ], 0, @now}}
    end

    test "with one usable and one never checked: a warning naming the never-checked one" do
      indexer!(:newznab, "a.example", %{priority: 1}) |> record!([{:success, 0}])
      b = indexer!(:newznab, "b.example", %{priority: 2})

      assert Native.health() ==
               {:warning, {:native_indexers, [%{name: b.name, state: :never_checked}], 0, @now}}
    end

    test "judges every state and stamps the reason at one reading of the clock" do
      indexer!(:newznab, "a.example", %{priority: 1}) |> record!([{:success, 0}])
      b = indexer!(:newznab, "b.example", %{priority: 2})
      reads = :counters.new(1, [])

      ConfigCase.put_env(Native,
        clock: fn ->
          :counters.add(reads, 1, 1)
          if :counters.get(reads, 1) == 1, do: @now, else: at(3_600)
        end
      )

      assert Native.health() ==
               {:warning, {:native_indexers, [%{name: b.name, state: :never_checked}], 0, @now}}

      assert :counters.get(reads, 1) == 1
    end

    test "lists an undecryptable enabled indexer" do
      indexer!(:newznab, "a.example", %{priority: 1}) |> record!([{:success, 0}])
      b = indexer!(:newznab, "b.example", %{priority: 2})
      :ok = undecryptable!(b)

      assert Native.health() ==
               {:warning, {:native_indexers, [%{name: b.name, state: :undecryptable}], 0, @now}}
    end

    test "with every enabled indexer usable: ok, a disabled one aside" do
      indexer!(:newznab, "a.example") |> record!([{:success, 0}])
      indexer!(:newznab, "b.example") |> record!([{:success, -30}])
      indexer!(:newznab, "off.example") |> disable!()

      assert Native.health() == :ok
    end

    test "each part of the usable rule: disabled, not supported, a running backoff, rejected" do
      indexer!(:newznab, "ok.example", %{priority: 1}) |> record!([{:success, 0}])

      unusable = [
        indexer!(:torznab, "flare.example", %{priority: 2, flaresolverr: true})
        |> record!([{:success, 0}]),
        indexer!(:newznab, "limit.example", %{priority: 3})
        |> record!([{:success, -60}, {{:limit, at(600)}, 0}]),
        indexer!(:newznab, "fail.example", %{priority: 4})
        |> record!([{:success, -60}, {:timeout, 0}]),
        indexer!(:newznab, "rejected.example", %{priority: 5})
        |> record!([{:success, -60}, {:rejected_credentials, 0}])
      ]

      assert {:warning, {:native_indexers, listed, 0, @now}} = Native.health()
      assert Enum.map(listed, & &1.name) == Enum.map(unusable, & &1.name)
    end

    test "lists at most 5 indexers, in priority order, and counts the rest" do
      names =
        for n <- 1..7 do
          indexer!(:newznab, "i#{n}.example", %{priority: n}).name
        end

      assert {:error, {:native_indexers, listed, 2, @now}} = Native.health()
      assert Enum.map(listed, & &1.name) == Enum.take(names, 5)
    end
  end

  describe "passes_gate?/0" do
    test "passes with one usable indexer" do
      indexer!(:newznab, "a.example") |> record!([{:success, 0}])
      assert IndexerState.passes_gate?()
    end

    test "passes with one indexer in a limit backoff" do
      indexer!(:newznab, "a.example") |> record!([{{:limit, at(600)}, 0}])
      assert IndexerState.passes_gate?()
    end

    test "stops passing once a limit ends, until the next answer" do
      indexer!(:newznab, "a.example") |> record!([{:success, -60}, {{:limit, nil}, 0}])
      assert IndexerState.passes_gate?(at(3_599))
      refute IndexerState.passes_gate?(at(3_600))
    end

    test "stops passing once a limit kept across an edit ends" do
      indexer =
        indexer!(:newznab, "a.example") |> record!([{:success, -120}, {{:limit, nil}, -60}])

      {:ok, _edited} = Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/v2"})

      assert IndexerState.passes_gate?(at(3_539))
      refute IndexerState.passes_gate?(at(3_540))
    end

    test "fails with only never-checked, failure-backoff, retry-due or rejected indexers" do
      indexer!(:newznab, "fresh.example")
      indexer!(:newznab, "fail.example") |> record!([{:success, -60}, {:timeout, 0}])
      indexer!(:newznab, "due.example") |> record!([{:success, -600}, {:timeout, -300}])

      indexer!(:newznab, "rejected.example")
      |> record!([{:success, -60}, {:rejected_credentials, 0}])

      indexer!(:newznab, "locked.example") |> record!([{:success, 0}]) |> undecryptable!()

      refute IndexerState.passes_gate?()
    end

    test "fails with no enabled indexer" do
      refute IndexerState.passes_gate?()
      indexer!(:newznab, "off.example") |> record!([{:success, 0}]) |> disable!()
      refute IndexerState.passes_gate?()
    end

    test "fails once the last passing indexer is disabled" do
      indexer = indexer!(:newznab, "a.example") |> record!([{:success, 0}])
      indexer!(:newznab, "fresh.example")
      assert IndexerState.passes_gate?()

      disable!(indexer)
      refute IndexerState.passes_gate?()
    end
  end
end
