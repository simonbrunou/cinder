defmodule Cinder.Download.StallReaperTest do
  use ExUnit.Case, async: false

  alias Cinder.Download.StallReaper

  # These tests mutate the module's global config; async: false + save/restore.
  setup do
    saved = Application.get_env(:cinder, StallReaper)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, StallReaper, saved),
        else: Application.delete_env(:cinder, StallReaper)
    end)

    :ok
  end

  defp configure(opts), do: Application.put_env(:cinder, StallReaper, opts)

  @now ~U[2026-07-21 12:00:00Z]

  defp reap?(clock, status), do: StallReaper.reap?(clock, clock, status, @now)

  describe "reap?/4" do
    setup do
      configure(
        enabled: true,
        stall_timeout: :timer.hours(2),
        no_seeders_timeout: :timer.minutes(30)
      )
    end

    test "reaps a 0-seeder torrent stalled past the no-seeders window" do
      stalled_at = DateTime.add(@now, -31, :minute)
      assert reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 0})
    end

    test "does not reap a 0-seeder torrent still inside the no-seeders window" do
      stalled_at = DateTime.add(@now, -29, :minute)
      refute reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 0})
    end

    test "a seeded torrent uses the longer stall window, not the no-seeders one" do
      stalled_at = DateTime.add(@now, -31, :minute)
      # 31 min > 30 (no-seeders) but < 120 (stall): a seeded swarm is NOT reaped yet.
      refute reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 5})

      really_stalled = DateTime.add(@now, -121, :minute)
      assert reap?(really_stalled, %{state: :downloading, speed: 0, seeders: 5})
    end

    test "unknown seeders (nil) falls back to the longer stall window" do
      stalled_at = DateTime.add(@now, -31, :minute)
      refute reap?(stalled_at, %{state: :downloading, speed: 0, seeders: nil})

      really_stalled = DateTime.add(@now, -121, :minute)

      assert reap?(really_stalled, %{state: :downloading, speed: 0, seeders: nil})
    end

    test "a usenet download (nil speed) is not seed-window-reaped inside the absolute cap" do
      # nil speed never triggers the torrent-only seed window; 23h is still inside the 24h cap.
      recent = DateTime.add(@now, -23, :hour)
      refute reap?(recent, %{state: :downloading, speed: nil})
    end

    test "reaps a usenet download (nil speed) once it crosses the absolute cap" do
      # The wedged-SABnzbd case the torrent-only seed window can never catch: past 24h it reaps.
      wedged = DateTime.add(@now, -25, :hour)
      assert reap?(wedged, %{state: :downloading, speed: nil})
    end

    test "does not reap a recently-updated download regardless of speed" do
      # Both clocks are fresh, so neither reap path fires at any speed.
      fresh = DateTime.add(@now, -1, :minute)
      refute reap?(fresh, %{state: :downloading, speed: 1_500_000, seeders: 0})
      refute reap?(fresh, %{state: :downloading, speed: nil})
    end

    test "the absolute cap reaps regardless of reported speed" do
      # A frozen job whose client still reports a stale non-zero speed is reaped past the cap —
      # a genuinely progressing download advances its dedicated progress clock.
      wedged = DateTime.add(@now, -25, :hour)
      assert reap?(wedged, %{state: :downloading, speed: 1_500_000, seeders: 5})
    end

    test "the absolute cap ignores recent speed and ETA activity" do
      recent_activity = DateTime.add(@now, -1, :minute)
      no_progress = DateTime.add(@now, -25, :hour)

      assert StallReaper.reap?(
               recent_activity,
               no_progress,
               %{state: :downloading, speed: 1_024, eta: 500},
               @now
             )
    end

    test "tolerates a partial status map with no speed/seeders key" do
      recent = DateTime.add(@now, -1, :minute)
      refute reap?(recent, %{state: :downloading})
    end

    test "a partial status map past the absolute cap still reaps" do
      wedged = DateTime.add(@now, -25, :hour)
      assert reap?(wedged, %{state: :downloading})
    end

    test "a shorter configured cap reaps a nil-speed download sooner" do
      configure(enabled: true, max_downloading_timeout: :timer.hours(6))
      six_h_one = DateTime.add(@now, -361, :minute)
      assert reap?(six_h_one, %{state: :downloading, speed: nil})

      inside = DateTime.add(@now, -359, :minute)
      refute reap?(inside, %{state: :downloading, speed: nil})
    end
  end

  describe "config accessors" do
    test "default off with the shipped thresholds when unconfigured" do
      Application.delete_env(:cinder, StallReaper)
      refute StallReaper.enabled?()
      assert StallReaper.stall_timeout() == :timer.hours(2)
      assert StallReaper.no_seeders_timeout() == :timer.minutes(30)
      assert StallReaper.max_downloading_timeout() == :timer.hours(24)
    end

    test "reads enabled + custom thresholds from config" do
      configure(
        enabled: true,
        stall_timeout: 111,
        no_seeders_timeout: 22,
        max_downloading_timeout: 33
      )

      assert StallReaper.enabled?()
      assert StallReaper.stall_timeout() == 111
      assert StallReaper.no_seeders_timeout() == 22
      assert StallReaper.max_downloading_timeout() == 33
    end
  end
end
