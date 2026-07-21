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

  describe "reap?/3" do
    setup do
      configure(
        enabled: true,
        stall_timeout: :timer.hours(2),
        no_seeders_timeout: :timer.minutes(30)
      )
    end

    test "reaps a 0-seeder torrent stalled past the no-seeders window" do
      stalled_at = DateTime.add(@now, -31, :minute)
      assert StallReaper.reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 0}, @now)
    end

    test "does not reap a 0-seeder torrent still inside the no-seeders window" do
      stalled_at = DateTime.add(@now, -29, :minute)
      refute StallReaper.reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 0}, @now)
    end

    test "a seeded torrent uses the longer stall window, not the no-seeders one" do
      stalled_at = DateTime.add(@now, -31, :minute)
      # 31 min > 30 (no-seeders) but < 120 (stall): a seeded swarm is NOT reaped yet.
      refute StallReaper.reap?(stalled_at, %{state: :downloading, speed: 0, seeders: 5}, @now)

      really_stalled = DateTime.add(@now, -121, :minute)
      assert StallReaper.reap?(really_stalled, %{state: :downloading, speed: 0, seeders: 5}, @now)
    end

    test "unknown seeders (nil) falls back to the longer stall window" do
      stalled_at = DateTime.add(@now, -31, :minute)
      refute StallReaper.reap?(stalled_at, %{state: :downloading, speed: 0, seeders: nil}, @now)

      really_stalled = DateTime.add(@now, -121, :minute)

      assert StallReaper.reap?(
               really_stalled,
               %{state: :downloading, speed: 0, seeders: nil},
               @now
             )
    end

    test "never reaps a usenet download (nil speed), regardless of age" do
      ancient = DateTime.add(@now, -10, :day)
      refute StallReaper.reap?(ancient, %{state: :downloading, speed: nil}, @now)
    end

    test "never reaps a download that is still moving (speed > 0)" do
      ancient = DateTime.add(@now, -10, :day)

      refute StallReaper.reap?(
               ancient,
               %{state: :downloading, speed: 1_500_000, seeders: 0},
               @now
             )
    end

    test "tolerates a partial status map with no speed/seeders key" do
      ancient = DateTime.add(@now, -10, :day)
      refute StallReaper.reap?(ancient, %{state: :downloading}, @now)
    end
  end

  describe "config accessors" do
    test "default off with the shipped thresholds when unconfigured" do
      Application.delete_env(:cinder, StallReaper)
      refute StallReaper.enabled?()
      assert StallReaper.stall_timeout() == :timer.hours(2)
      assert StallReaper.no_seeders_timeout() == :timer.minutes(30)
    end

    test "reads enabled + custom thresholds from config" do
      configure(enabled: true, stall_timeout: 111, no_seeders_timeout: 22)
      assert StallReaper.enabled?()
      assert StallReaper.stall_timeout() == 111
      assert StallReaper.no_seeders_timeout() == 22
    end
  end
end
