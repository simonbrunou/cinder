defmodule CinderWeb.ProwlarrImportComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.ProwlarrImportComponents

  defp report(created, tests_started) do
    render_component(&ProwlarrImportComponents.import_step/1,
      dialog: %{
        phase: :report,
        report: %{created: created, tests_started: tests_started, flaresolverr_url_saved: false},
        skipped: []
      },
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    )
  end

  defp created(id, name, enabled) do
    notes = if enabled, do: [], else: [:created_disabled_no_key]
    %{id: id, prowlarr_id: id + 100, name: name, enabled: enabled, notes: notes}
  end

  test "the report says Cinder tests each enabled indexer it created once every such Test started" do
    created = [created(1, "One", true), created(2, "Two", true), created(3, "Three", false)]
    html = report(created, [1, 2])

    assert html =~ "Cinder is testing each enabled indexer it created."
  end

  test "when only some of those Tests started, the report names the indexers Cinder tests" do
    html = report([created(1, "One", true), created(2, "Two", true)], [2])

    refute html =~ "each enabled indexer"
    assert html =~ "Cinder is testing Two."
  end

  test "with no Test started, the report says nothing about testing" do
    html = report([created(1, "One", true)], [])

    refute html =~ "import-report-testing"
    refute html =~ "Cinder is testing"
  end
end
