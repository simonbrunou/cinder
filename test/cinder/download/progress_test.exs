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

  describe "changes/3 on a client-wide pause" do
    @now ~U[2026-11-23 12:00:00Z]

    defp row(attrs) do
      Map.merge(
        %{
          download_progress: 0.0,
          download_speed: nil,
          download_eta: nil,
          download_paused_at: nil,
          download_progress_at: DateTime.add(@now, -1, :hour)
        },
        attrs
      )
    end

    test "the first paused report marks the pause" do
      assert Progress.changes(row(%{}), %{client_paused: true}, @now) ==
               %{download_paused_at: @now}
    end

    test "a later paused report changes nothing" do
      paused = row(%{download_paused_at: DateTime.add(@now, -5, :minute)})

      assert Progress.changes(paused, %{client_paused: true}, @now) == %{}
    end

    test "a resume clears the mark and moves the clock past the paused time only" do
      paused =
        row(%{
          download_progress_at: DateTime.add(@now, -65, :hour),
          download_paused_at: DateTime.add(@now, -42, :hour)
        })

      assert Progress.changes(paused, %{client_paused: false}, @now) == %{
               download_paused_at: nil,
               download_progress_at: DateTime.add(@now, -23, :hour)
             }
    end

    test "a resume after progress during the pause leaves the clock at now, never past it" do
      paused =
        row(%{
          download_paused_at: DateTime.add(@now, -2, :hour),
          download_progress_at: DateTime.add(@now, -1, :hour)
        })

      assert Progress.changes(paused, %{client_paused: false}, @now) ==
               %{download_paused_at: nil, download_progress_at: @now}
    end

    test "a resume on a row with no clock starts the clock at now" do
      paused =
        row(%{download_progress_at: nil, download_paused_at: DateTime.add(@now, -1, :hour)})

      assert Progress.changes(paused, %{client_paused: false}, @now) ==
               %{download_paused_at: nil, download_progress_at: @now}
    end

    test "a pause stamped after now, a stepped wall clock, keeps the clock where it is" do
      clock = DateTime.add(@now, -3, :hour)

      paused =
        row(%{download_progress_at: clock, download_paused_at: DateTime.add(@now, 1, :hour)})

      assert Progress.changes(paused, %{client_paused: false}, @now) ==
               %{download_paused_at: nil, download_progress_at: clock}
    end

    test "a running report on a row that is not paused changes nothing" do
      assert Progress.changes(row(%{}), %{client_paused: false}, @now) == %{}
    end

    test "a report that does not say leaves the pause alone" do
      paused = row(%{download_paused_at: DateTime.add(@now, -5, :minute), download_eta: 60})

      assert Progress.changes(paused, %{download_speed: nil, download_eta: nil}, @now) ==
               %{download_eta: nil}
    end

    # Past the 24 h cap by more than a minute, the reaper may not have reached the row before this
    # report, so the whole gap counts as paused: the resume then gives a full window.
    test "a first sighting more than 24 h 1 min after the clock dates the pause from the clock" do
      clock = @now |> DateTime.add(-24, :hour) |> DateTime.add(-61, :second)

      assert Progress.changes(row(%{download_progress_at: clock}), %{client_paused: true}, @now) ==
               %{download_paused_at: clock}
    end

    test "a first sighting exactly 24 h 1 min after the clock dates the pause from now" do
      clock = @now |> DateTime.add(-24, :hour) |> DateTime.add(-60, :second)

      assert Progress.changes(row(%{download_progress_at: clock}), %{client_paused: true}, @now) ==
               %{download_paused_at: @now}
    end

    test "a first sighting on a row with no clock dates the pause from now" do
      assert Progress.changes(row(%{download_progress_at: nil}), %{client_paused: true}, @now) ==
               %{download_paused_at: @now}
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
