defmodule CinderWeb.SettingsIndexerSourceTest do
  # The "Indexer source" select at the top of the Indexers group of /settings (#1662): the switch
  # refusal `Cinder.Indexers.check_source_switch/2` answers, the source lines under the select,
  # and the indexers table reading its rows again after a save. Native's clock is pinned, so the
  # gate (`IndexerState.passes_gate?/1`) reads each recorded answer at a fixed instant.
  #
  # Not async: each submit saves settings, which rewrite the `:cinder` env, and Native's clock is
  # app-wide.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.NewznabFixtures, only: [indexer!: 2, indexer!: 3]

  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.{ConfigCase, Settings}

  @now ~U[2026-11-26 12:00:00Z]

  @refusal "Built-in needs at least one enabled indexer that works or is waiting out a rate limit. Add, enable or test one below first."
  @grabs_line "Grabs already found through Prowlarr still download through it."
  @searches_line "Searches go through Prowlarr. The indexers below can still be added, tested and imported; Cinder searches them once you switch to Built-in."

  setup :register_and_log_in_admin
  setup :reset_cinder_env

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

  # An enabled indexer that fails the gate: a first answer that timed out starts a failure
  # backoff.
  defp failing_indexer!, do: indexer!(:newznab, "fail.example") |> record!([{:timeout, 0}])
  defp usable_indexer!, do: indexer!(:newznab, "ok.example") |> record!([{:success, 0}])

  defp submit(lv, params) do
    lv |> form("#settings-form", params) |> render_submit()
  end

  defp source_error?(lv), do: has_element?(lv, "#indexer_source-error", @refusal)

  defp flash_error?(lv, text), do: has_element?(lv, "#flash-error", text)

  describe "the select" do
    test "is the first control of the Indexers group, labelled, with Prowlarr and Built-in",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               "#settings-group-indexer > .collapse-content > :first-child select#indexer_source[name=indexer_source]"
             )

      # The section help, with its link, comes after the select's block.
      assert has_element?(
               lv,
               "#settings-group-indexer > .collapse-content > :first-child + .setup-section-help"
             )

      assert has_element?(lv, ~s(label[for="indexer_source"]), "Indexer source")
      assert has_element?(lv, ~s(#indexer_source option[value="prowlarr"]), "Prowlarr")
      assert has_element?(lv, ~s(#indexer_source option[value="native"]), "Built-in")
      assert has_element?(lv, ~s(#indexer_source option[value="prowlarr"][selected]))
    end

    test "shows the stored source", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "native"})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, ~s(#indexer_source option[value="native"][selected]))
    end

    test "renders on /settings and in the Indexers step of /setup (#1663)", %{conn: conn} do
      {:ok, settings, _html} = live(conn, ~p"/settings")
      assert has_element?(settings, ~s(#settings-form [name="indexer_source"]))

      {:ok, setup, _html} = live(conn, ~p"/setup")
      assert has_element?(setup, ~s(#setup-form #settings-group-indexer [name="indexer_source"]))
    end
  end

  describe "a save that switches to Built-in" do
    test "is refused while no indexer passes the gate, and stores nothing", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{
        "indexer_source" => "native",
        "tmdb_token" => "new-token",
        "prowlarr_url" => "http://new:9696"
      })

      assert source_error?(lv)
      assert flash_error?(lv, @refusal)
      # The refusal keeps what the admin typed in the other fields.
      assert has_element?(lv, ~s(#prowlarr_url[value="http://new:9696"]))
      assert has_element?(lv, ~s(#indexer_source[aria-invalid="true"]))

      assert has_element?(
               lv,
               ~s(#indexer_source[aria-describedby="indexer_source-error indexer_source-help"])
             )

      assert has_element?(lv, ~s(#indexer_source option[value="native"][selected]))
      assert_push_event(lv, "focus-invalid", %{id: "indexer_source"})
      refute has_element?(lv, "#flash-info")
      assert Settings.get("indexer_source") == "prowlarr"
      assert Settings.get("tmdb_token") == nil

      # The source lines read the saved source, not the select's unsaved value.
      assert has_element?(lv, "#indexer_source-help", @searches_line)

      # The rule compares with the stored source again, not with the form the refusal kept.
      submit(lv, %{"indexer_source" => "native", "tmdb_token" => "new-token"})

      assert source_error?(lv)
      assert Settings.get("indexer_source") == "prowlarr"
      assert Settings.get("tmdb_token") == nil
    end

    test "is refused with no stored source while the bootstrap is Prowlarr", %{conn: conn} do
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native", "tmdb_token" => "new-token"})

      assert source_error?(lv)
      assert Settings.get("indexer_source") == nil
      assert Settings.get("tmdb_token") == nil
    end

    test "is stored with one usable indexer, whose last answer was a success", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      failing_indexer!()
      usable_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native", "tmdb_token" => "new-token"})

      assert has_element?(lv, "#flash-info", "Settings saved.")
      refute has_element?(lv, "#indexer_source-error")
      assert Settings.get("indexer_source") == "native"
      assert Settings.get("tmdb_token") == "new-token"
      assert Application.fetch_env!(:cinder, :indexer_source) == Native
    end

    test "is stored with one indexer in a limit backoff and no usable one", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      failing_indexer!()
      indexer!(:newznab, "limit.example") |> record!([{{:limit, at(600)}, 0}])
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native", "tmdb_token" => "new-token"})

      assert has_element?(lv, "#flash-info", "Settings saved.")
      assert Settings.get("indexer_source") == "native"
      assert Settings.get("tmdb_token") == "new-token"
    end

    test "is stored once an indexer passes, and the refusal goes away", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native"})
      assert source_error?(lv)

      usable_indexer!()
      submit(lv, %{"indexer_source" => "native"})

      refute has_element?(lv, "#indexer_source-error")
      refute has_element?(lv, ~s(#indexer_source[aria-invalid]))
      assert Settings.get("indexer_source") == "native"
    end

    # Each submit starts from a cleared flash, so a saved retry drops the refusal's flash and a
    # refusal after a save drops the save's.
    test "a saved retry clears the refusal's flash, and a refusal clears the save's",
         %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native"})
      assert flash_error?(lv, @refusal)

      usable = usable_indexer!()
      submit(lv, %{"indexer_source" => "native"})

      assert has_element?(lv, "#flash-info", "Settings saved.")
      refute has_element?(lv, "#flash-error")

      submit(lv, %{"indexer_source" => "prowlarr"})
      assert has_element?(lv, "#flash-info", "Settings saved.")
      Cinder.Repo.delete!(usable)

      submit(lv, %{"indexer_source" => "native"})

      assert flash_error?(lv, @refusal)
      refute has_element?(lv, "#flash-info")
    end
  end

  describe "a save that does not switch to Built-in" do
    test "keeping Built-in stores the other fields while no indexer passes the gate",
         %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "native"})
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "native", "tmdb_token" => "new-token"})

      assert has_element?(lv, "#flash-info", "Settings saved.")
      refute has_element?(lv, "#indexer_source-error")
      assert Settings.get("indexer_source") == "native"
      assert Settings.get("tmdb_token") == "new-token"
    end

    test "switching to Prowlarr is stored while no indexer passes the gate", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "native"})
      failing_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      submit(lv, %{"indexer_source" => "prowlarr", "tmdb_token" => "new-token"})

      assert has_element?(lv, "#flash-info", "Settings saved.")
      assert Settings.get("indexer_source") == "prowlarr"
      assert Settings.get("tmdb_token") == "new-token"
      assert Application.fetch_env!(:cinder, :indexer_source) == Prowlarr
    end

    test "a source that is no option is rejected with the shape's message", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      usable_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for forged <- ["builtin", " native ", ""] do
        lv
        |> render_hook("save", %{"indexer_source" => forged, "tmdb_token" => "new-token"})

        assert {forged,
                has_element?(lv, "#indexer_source-error", "Choose a listed indexer source.")} ==
                 {forged, true}

        refute source_error?(lv)
        assert Settings.get("indexer_source") == "prowlarr"
        assert Settings.get("tmdb_token") == nil
      end
    end
  end

  test "a refused switch, then a source that is no option, shows the shape's message",
       %{conn: conn} do
    :ok = Settings.save(%{"indexer_source" => "prowlarr"})
    failing_indexer!()
    {:ok, lv, _html} = live(conn, ~p"/settings")

    submit(lv, %{"indexer_source" => "native"})
    assert source_error?(lv)

    render_hook(lv, "save", %{"indexer_source" => "builtin"})

    assert has_element?(lv, "#indexer_source-error", "Choose a listed indexer source.")
    refute source_error?(lv)
    assert Settings.get("indexer_source") == "prowlarr"
  end

  describe "the source line" do
    test "with Built-in and a Prowlarr URL, says grabs found through Prowlarr still use it",
         %{conn: conn} do
      # The suite's boot capture holds config/test.exs's Prowlarr URL, which each save rebuilds
      # the env from: drop it, so the line comes from the saved row alone.
      ConfigCase.update_boot_capture(Prowlarr, &Keyword.put(&1, :base_url, nil))
      :ok = Settings.save(%{"indexer_source" => "native", "prowlarr_url" => "http://p:9696"})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexer_source-help", @grabs_line)
      refute has_element?(lv, "#indexer_source-help", "Searches go through Prowlarr")
    end

    test "with Built-in and no Prowlarr URL, is absent", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "native"})
      ConfigCase.put_config(Prowlarr, base_url: nil)
      {:ok, lv, _html} = live(conn, ~p"/settings")

      # Positive control: the select renders, so the refute below reads the right group.
      assert has_element?(lv, "#indexer_source")
      refute has_element?(lv, "#indexer_source-help")
    end

    test "with Prowlarr, says searches go through Prowlarr", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(lv, "#indexer_source-help", @searches_line)
      refute has_element?(lv, "#indexer_source-help", @grabs_line)
    end

    test "follows a saved switch", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      usable_indexer!()
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer_source-help", @searches_line)

      submit(lv, %{"indexer_source" => "native"})

      assert has_element?(lv, "#indexer_source-help", @grabs_line)
    end
  end

  describe "the indexers table" do
    @question "Delete Alpha? Its grabs still waiting to be sent are dropped: movies and episodes search again, books wait for you."
    @only "It is your only working indexer, so searches stop until another one works."

    defp confirm?(lv, id, text),
      do: has_element?(lv, ~s(#indexer-#{id}-delete[data-confirm="#{text}"]))

    test "a saved switch makes Delete's warning follow the new source", %{conn: conn} do
      :ok = Settings.save(%{"indexer_source" => "prowlarr"})
      alpha = indexer!(:newznab, "a.example", %{name: "Alpha"}) |> record!([{:success, 0}])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert confirm?(lv, alpha.id, @question)

      submit(lv, %{"indexer_source" => "native"})
      # The save's `send_update/3` reaches the view's own mailbox: one render before the check
      # (docs/agents/testing.md, the bullet on `send_update/3`).
      render(lv)

      assert confirm?(lv, alpha.id, @question <> " " <> @only)

      submit(lv, %{"indexer_source" => "prowlarr"})
      render(lv)

      assert confirm?(lv, alpha.id, @question)
    end
  end
end
