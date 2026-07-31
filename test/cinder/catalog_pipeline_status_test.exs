defmodule Cinder.CatalogPipelineStatusTest do
  # Pure unit tests for the pipeline-status classification — no DB, no fixtures.
  use ExUnit.Case, async: true

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @active [:requested, :searching, :downloading, :downloaded, :upgrading]
  @parked [:no_match, :search_failed, :import_failed]
  @done [:available, :cancelled]

  describe "pipeline_statuses/0" do
    test "returns exactly the active in-flight statuses, in pipeline order" do
      assert Catalog.pipeline_statuses() == @active
    end
  end

  describe "in_pipeline?/1" do
    test "true for every active status" do
      for status <- @active do
        assert Catalog.in_pipeline?(%{status: status}),
               "expected #{inspect(status)} to be in the pipeline"
      end
    end

    test "true for every parked failure (they need a retry, so they stay on live surfaces)" do
      for status <- @parked do
        assert Catalog.in_pipeline?(%{status: status}),
               "expected #{inspect(status)} to be in the pipeline"
      end
    end

    test "false for the terminal-done statuses" do
      for status <- @done do
        refute Catalog.in_pipeline?(%{status: status}),
               "expected #{inspect(status)} to be terminal-done"
      end
    end

    test "accepts a Movie struct" do
      assert Catalog.in_pipeline?(%Movie{status: :downloading})
      refute Catalog.in_pipeline?(%Movie{status: :available})
    end
  end

  test "the active/parked/done split covers Movie's status enum exactly" do
    # Drift guard: adding a status to the Movie schema fails here until it is
    # classified in Cinder.Catalog's pipeline-status classification (and this split).
    assert Enum.sort(@active ++ @parked ++ @done) ==
             Enum.sort(Ecto.Enum.values(Movie, :status))
  end
end
