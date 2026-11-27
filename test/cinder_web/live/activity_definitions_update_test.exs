defmodule CinderWeb.ActivityDefinitionsUpdateTest do
  # The definitions update job's row in /activity's background sweeps (#1669), with its label
  # from #1676.
  # Not async: the job's status lives in `:persistent_term`, which the test sets.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Indexers.Definitions.Updater

  setup :register_and_log_in_admin

  setup do
    :persistent_term.erase({Updater, :status})
    on_exit(fn -> :persistent_term.erase({Updater, :status}) end)
    :ok
  end

  test "lists the definitions update with its last run and next run", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert has_element?(lv, "#activity-jobs #job-Updater", "Update indexer definitions")
    assert has_element?(lv, "#job-Updater", "Last run: not yet")

    # A failed run with no set loaded ended 30 s ago and armed the 5-minute retry.
    :persistent_term.put(
      {Updater, :status},
      %{last_run_at: DateTime.add(DateTime.utc_now(), -30, :second), interval: :timer.minutes(5)}
    )

    {:ok, lv, _html} = live(conn, ~p"/activity")
    assert has_element?(lv, "#job-Updater", "Next: in 4m")
  end
end
