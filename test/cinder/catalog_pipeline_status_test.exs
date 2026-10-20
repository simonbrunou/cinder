defmodule Cinder.CatalogPipelineStatusTest do
  # Pure unit tests for the pipeline-status classification — no DB, no fixtures.
  use ExUnit.Case, async: true

  alias Cinder.Catalog.{Movie, MovieLifecycle}

  @active [:requested, :searching, :downloading, :downloaded, :upgrading]
  @parked [:no_match, :search_failed, :import_failed]
  @done [:available, :cancelled]

  describe "pipeline_statuses/0" do
    test "returns exactly the active in-flight statuses, in pipeline order" do
      assert MovieLifecycle.pipeline_statuses() == @active
    end
  end

  describe "parked_statuses/0" do
    test "returns exactly the parked failure statuses" do
      assert MovieLifecycle.parked_statuses() == @parked
    end

    test "is the set retry/1 accepts (Retry shows exactly where it can succeed)" do
      for status <- Ecto.Enum.values(Movie, :status) -- @parked do
        assert MovieLifecycle.retry(%Movie{id: 0, status: status}) ==
                 {:error, :not_retryable},
               "expected #{inspect(status)} to be rejected by retry/1"
      end
    end
  end

  test "the active/parked/done split covers Movie's status enum exactly" do
    # Drift guard: adding a status to the Movie schema fails here until it is
    # classified in Cinder.Catalog's pipeline-status classification (and this split).
    assert Enum.sort(@active ++ @parked ++ @done) ==
             Enum.sort(Ecto.Enum.values(Movie, :status))
  end
end
