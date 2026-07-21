defmodule Cinder.JobsTest do
  # async: false — status/0 reads process-global :persistent_term; erase it per test so a recorded
  # last-run can't bleed into other suites (e.g. ActivityLive's "not yet" assertion).
  use ExUnit.Case, async: false

  alias Cinder.Catalog.Refresher

  setup do
    :persistent_term.erase({Refresher, :last_run})
    on_exit(fn -> :persistent_term.erase({Refresher, :last_run}) end)
    :ok
  end

  test "statuses/0 snapshots every background sweep" do
    statuses = Cinder.Jobs.statuses()
    modules = Enum.map(statuses, & &1.module)

    assert Cinder.Catalog.Refresher in modules
    assert Cinder.Subtitles.Sweeper in modules
    assert Enum.all?(statuses, &is_integer(&1.interval))
  end

  test "a worker's status reflects the recorded last run" do
    assert Refresher.status().last_run_at == nil

    at = DateTime.utc_now()
    :persistent_term.put({Refresher, :last_run}, at)

    assert Refresher.status().last_run_at == at
  end
end
