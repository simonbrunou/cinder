defmodule Cinder.Settings.IndexerSourceTest do
  # The `indexer_source` setting, its resolver (#1651) and the value its /settings select shows
  # (#1662). Not async: the cases set process-global
  # OS env vars and save settings, which rewrite the `:cinder` env.
  use Cinder.DataCase, async: false

  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr}
  alias Cinder.ConfigCase
  alias Cinder.Settings
  alias Cinder.Settings.{Definition, Registry, Setting, Shape}

  setup do
    ConfigCase.restore_env_on_exit(Settings.env_keys())
    ConfigCase.put_prowlarr_env(nil, nil)
  end

  defp spec do
    {:indexer_source, spec} = Registry.definition("indexer_source").shape
    spec
  end

  defp put_os_env(vars), do: Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

  describe "Shape.running_indexer_source/3" do
    # One row per rule, each set up so the rule below it would answer otherwise. The rows that
    # leave the captured mock in place also set PROWLARR_URL: a captured mock ranked below the env
    # vars answers Prowlarr there. The listed captured module is Prowlarr, as config.exs captures
    # in prod, so on a row with no listed option stored a Native answer comes from the
    # fresh-install default alone (#1689).
    for {name, stored, captured, vars, expected} <- [
          {"stored native", "native", IndexerMock, [{"PROWLARR_URL", "http://p"}], Native},
          {"stored native beats a set PROWLARR_API_KEY", "native", Prowlarr,
           [{"PROWLARR_API_KEY", "k"}], Native},
          {"stored prowlarr", "prowlarr", IndexerMock, [], Prowlarr},
          {"stored prowlarr with no env var", "prowlarr", Prowlarr, [], Prowlarr},
          {"a stored value that is no option reads as none stored", "builtin", IndexerMock,
           [{"PROWLARR_URL", "http://p"}], IndexerMock},
          {"no row and the captured IndexerMock", nil, IndexerMock,
           [{"PROWLARR_URL", "http://p"}, {"PROWLARR_API_KEY", "k"}], IndexerMock},
          {"no row, a listed captured module and PROWLARR_URL set", nil, Prowlarr,
           [{"PROWLARR_URL", "http://p"}], Prowlarr},
          {"no row, a listed captured module and PROWLARR_API_KEY set", nil, Prowlarr,
           [{"PROWLARR_API_KEY", "k"}], Prowlarr},
          {"no row, a listed captured module and both blank", nil, Prowlarr,
           [{"PROWLARR_URL", " "}, {"PROWLARR_API_KEY", ""}], Native},
          {"no row, a listed captured module and no env var", nil, Prowlarr, [], Native},
          {"nothing set", nil, [], [], Native}
        ] do
      @stored stored
      @captured captured
      @vars vars
      @expected expected

      test name do
        put_os_env(@vars)

        assert Shape.running_indexer_source(spec(), @stored, @captured) == @expected
      end
    end
  end

  describe "the definition" do
    # #1662 renders it on /settings, in the Indexers group, saved with the form.
    test "is saved with the form, rendered by hand in the Indexers group and validated" do
      definition = Registry.definition("indexer_source")

      assert {definition.save, definition.render, definition.group} ==
               {:form, :custom, :indexer}

      assert {definition.label, definition.help} == {"Indexer source", nil}
      assert Definition.message(definition) == "Choose a listed indexer source."
      assert Definition.validated?(definition)

      assert Enum.map(spec().options, &{&1.value, &1.label, &1.module}) == [
               {"prowlarr", "Prowlarr", Prowlarr},
               {"native", "Built-in", Native}
             ]

      assert spec().default == "native"
    end

    test "a save_form/1 whose params carry a listed indexer_source stores it" do
      assert :ok =
               Settings.save_form(%{"indexer_source" => "native", "prowlarr_url" => "http://p"})

      assert Repo.get_by(Setting, key: "prowlarr_url")
      assert Repo.get_by(Setting, key: "indexer_source").value == "native"
      assert Application.fetch_env!(:cinder, :indexer_source) == Native
    end

    # `plan/3` trims what it stores, so a padded value must be refused, not stored trimmed.
    test "a save_form/1 with a value that is no option is refused and stores nothing" do
      for value <- ["builtin", " native ", "", "Native"] do
        assert {value, Settings.save_form(%{"indexer_source" => value, "prowlarr_url" => "x"})} ==
                 {value, {:error, ["indexer_source"]}}
      end

      refute Repo.get_by(Setting, key: "prowlarr_url")
      refute Repo.get_by(Setting, key: "indexer_source")
    end

    test "a save_form/1 without indexer_source leaves the stored source" do
      :ok = Settings.put("indexer_source", "native")

      assert :ok = Settings.save_form(%{"prowlarr_url" => "http://p"})

      assert Repo.get_by(Setting, key: "indexer_source").value == "native"
      assert Application.fetch_env!(:cinder, :indexer_source) == Native
    end
  end

  describe "the shown source" do
    test "the form shows a stored option, else the bootstrap choice, never the captured mock" do
      assert Settings.form_state().values["indexer_source"] == "native"
      assert Settings.indexer_source() == "native"
      assert Application.fetch_env!(:cinder, :indexer_source) == IndexerMock

      put_os_env([{"PROWLARR_URL", "http://p"}])
      assert Settings.form_state().values["indexer_source"] == "prowlarr"
      assert Settings.indexer_source() == "prowlarr"

      :ok = Settings.put("indexer_source", "native")
      assert Settings.form_state().values["indexer_source"] == "native"
      assert Settings.indexer_source() == "native"
    end

    test "a rejected submit keeps a listed source and drops one that is no option" do
      :ok = Settings.put("indexer_source", "native")

      assert Settings.form_state(%{"indexer_source" => "prowlarr"}).values["indexer_source"] ==
               "prowlarr"

      for value <- ["builtin", " prowlarr ", ""] do
        assert {value, Settings.form_state(%{"indexer_source" => value}).values["indexer_source"]} ==
                 {value, "native"}
      end
    end

    test "Shape.shown_indexer_source/2: a stored option, else a non-blank env var, else Built-in" do
      assert Shape.shown_indexer_source(spec(), "prowlarr") == "prowlarr"
      assert Shape.shown_indexer_source(spec(), nil) == "native"
      assert Shape.shown_indexer_source(spec(), "builtin") == "native"

      put_os_env([{"PROWLARR_API_KEY", "k"}])
      assert Shape.shown_indexer_source(spec(), nil) == "prowlarr"
      assert Shape.shown_indexer_source(spec(), "native") == "native"

      System.delete_env("PROWLARR_API_KEY")
      put_os_env([{"PROWLARR_URL", " "}])
      assert Shape.shown_indexer_source(spec(), nil) == "native"
    end
  end

  describe "the overlay" do
    # The boot capture is config.exs's Prowlarr, a listed option, as in prod: the overlay then
    # reads the stored row, the env vars and the fresh-install default (#1689).
    test "with prod's capture, it runs the stored source, else a non-blank env var, else Built-in" do
      ConfigCase.update_boot_capture(:indexer_source, fn _mock -> Prowlarr end)

      running = fn ->
        :ok = Settings.load_into_env()
        Application.fetch_env!(:cinder, :indexer_source)
      end

      assert running.() == Native

      put_os_env([{"PROWLARR_URL", "http://p"}])
      assert running.() == Prowlarr

      System.delete_env("PROWLARR_URL")
      put_os_env([{"PROWLARR_API_KEY", "k"}])
      assert running.() == Prowlarr

      put_os_env([{"PROWLARR_URL", " "}, {"PROWLARR_API_KEY", ""}])
      assert running.() == Native

      :ok = Settings.put("indexer_source", "prowlarr")
      assert running.() == Prowlarr

      put_os_env([{"PROWLARR_URL", "http://p"}])
      :ok = Settings.put("indexer_source", "native")
      assert running.() == Native
    end

    test "a stored choice picks its module, and deleting it brings back the boot capture" do
      :ok = Settings.put("indexer_source", "native")
      assert Application.fetch_env!(:cinder, :indexer_source) == Native

      :ok = Settings.put("indexer_source", "prowlarr")
      assert Application.fetch_env!(:cinder, :indexer_source) == Prowlarr

      :ok = Settings.delete("indexer_source")
      assert Application.fetch_env!(:cinder, :indexer_source) == IndexerMock
    end

    test "saving prowlarr_url writes the boot capture back to a deleted :indexer_source" do
      Application.delete_env(:cinder, :indexer_source)

      :ok = Settings.put("prowlarr_url", "http://prowlarr:9696")

      assert Application.fetch_env!(:cinder, :indexer_source) == IndexerMock
    end
  end
end
