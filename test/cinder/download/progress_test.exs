defmodule Cinder.Download.ProgressTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Progress

  @row %{download_progress: 40.0, download_speed: 1_000, download_eta: 600, status: :downloading}

  describe "changes/2" do
    test "keeps the fields a client report actually changed" do
      report = %{download_progress: 55.0, download_speed: 1_000, download_eta: 300}

      assert Progress.changes(@row, report) == %{download_progress: 55.0, download_eta: 300}
    end

    test "drops a progress that went backwards but keeps the rest of the report" do
      report = %{download_progress: 12.5, download_speed: 2_000}

      assert Progress.changes(@row, report) == %{download_speed: 2_000}
    end

    test "keeps the first progress a download reports" do
      assert Progress.changes(%{@row | download_progress: nil}, %{download_progress: 0.0}) ==
               %{download_progress: 0.0}
    end

    test "ignores everything but the three download metrics" do
      assert Progress.changes(@row, %{status: :downloaded, download_eta: 600}) == %{}
    end
  end

  describe "advanced?/2" do
    test "is true only when progress moved forward" do
      assert Progress.advanced?(40.0, 40.5)
      assert Progress.advanced?(nil, 0.1)
      refute Progress.advanced?(40.0, 40.0)
      refute Progress.advanced?(40.0, 10.0)
      refute Progress.advanced?(nil, 0.0)
      refute Progress.advanced?(40.0, nil)
    end
  end
end
