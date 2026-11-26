defmodule Cinder.IndexersSourceSwitchTest do
  # The indexer source switch rule (#1662): `Cinder.Indexers.check_source_switch/2`, which
  # `/settings` calls on every save, and `Cinder.Indexers.switch_source/1`, the entry #1688
  # calls over `rpc`. The gate is `IndexerState.passes_gate?/1` with Native's clock pinned.
  #
  # Not async: the cases save settings, which rewrite the `:cinder` env, and pin Native's clock.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures, only: [indexer!: 2]

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.{ConfigCase, Indexers, Settings}
  alias Cinder.Settings.Setting

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.restore_env_on_exit(Settings.env_keys())
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

  defp stored, do: Repo.get_by(Setting, key: "indexer_source")

  # An enabled indexer that fails the gate, so each refusal below has an indexer to count.
  defp failing_indexer!, do: indexer!(:newznab, "fail.example") |> record!([{:timeout, 0}])

  describe "check_source_switch/2" do
    test "refuses a switch to Built-in while no enabled indexer passes the gate" do
      failing_indexer!()

      assert Indexers.check_source_switch("native", "prowlarr") ==
               {:error, :no_working_indexer}
    end

    test "allows a switch to Built-in with one usable indexer, whose last answer was a success" do
      failing_indexer!()
      indexer!(:newznab, "a.example") |> record!([{:success, 0}])

      assert Indexers.check_source_switch("native", "prowlarr") == :ok
    end

    test "allows a switch to Built-in with one indexer in a limit backoff and no usable one" do
      failing_indexer!()
      indexer!(:newznab, "a.example") |> record!([{{:limit, at(600)}, 0}])

      assert Indexers.check_source_switch("native", "prowlarr") == :ok
    end

    test "never refuses a save that keeps Built-in" do
      failing_indexer!()

      assert Indexers.check_source_switch("native", "native") == :ok
    end

    test "never refuses a switch to Prowlarr, nor a submit with no source or another value" do
      failing_indexer!()

      for requested <- ["prowlarr", nil, "", " native ", "builtin"] do
        assert {requested, Indexers.check_source_switch(requested, "native")} == {requested, :ok}
      end
    end

    # The source the form showed: the stored row, else the bootstrap (`Prowlarr` in the test env,
    # since no `PROWLARR_*` variable picks another option and the default is `"prowlarr"`).
    test "with no current source given, compares with the stored row, else the bootstrap" do
      failing_indexer!()

      assert Indexers.check_source_switch("native") == {:error, :no_working_indexer}

      :ok = Settings.save(%{"indexer_source" => "native"})
      assert Indexers.check_source_switch("native") == :ok

      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      assert Indexers.check_source_switch("native") == {:error, :no_working_indexer}
    end
  end

  describe "switch_source/1" do
    test "with no indexer passing the gate, returns the refusal code and stores nothing" do
      failing_indexer!()

      assert Indexers.switch_source("native") == {:error, :no_working_indexer}
      refute stored()
      refute Application.fetch_env!(:cinder, :indexer_source) == Native
    end

    test "with one indexer passing the gate, stores Built-in and runs it" do
      indexer!(:newznab, "a.example") |> record!([{:success, 0}])

      assert Indexers.switch_source("native") == :ok
      assert stored().value == "native"
      assert Application.fetch_env!(:cinder, :indexer_source) == Native
    end

    # The write goes through `Settings.put/2`, which broadcasts once it has run the overlay.
    test "with Built-in already stored, returns :ok whatever the gate says and writes the row" do
      :ok = Settings.save(%{"indexer_source" => "native"})
      failing_indexer!()
      :ok = Settings.subscribe()

      assert Indexers.switch_source("native") == :ok
      assert_received :settings_updated
      assert stored().value == "native"
    end

    test "a refused switch broadcasts no settings write" do
      failing_indexer!()
      :ok = Settings.subscribe()

      assert Indexers.switch_source("native") == {:error, :no_working_indexer}
      # Positive control: the same subscription sees an allowed write.
      assert Indexers.switch_source("prowlarr") == :ok
      assert_received :settings_updated
      refute_received :settings_updated
    end

    test "switches to Prowlarr whatever the gate says" do
      :ok = Settings.save(%{"indexer_source" => "native"})
      failing_indexer!()

      assert Indexers.switch_source("prowlarr") == :ok
      assert stored().value == "prowlarr"
    end

    test "refuses a value that is no option and stores nothing" do
      indexer!(:newznab, "a.example") |> record!([{:success, 0}])

      for requested <- ["builtin", " native ", "", "Native"] do
        assert {requested, Indexers.switch_source(requested)} ==
                 {requested, {:error, :unknown_indexer_source}}
      end

      refute stored()
    end
  end
end
