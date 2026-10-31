defmodule Cinder.Test.DiskTask do
  @moduledoc """
  Waits for a test's task that can reach a `Cinder.Library.Filesystem.Disk` subprocess: the
  rooted helper or a bounded command such as the directory sync. `await/1` awaits the task, and
  `timeout_ms/0` is the timeout to pass to an `assert_receive` of a message the task sends after
  a Disk call.

  `config/test.exs` gives such a subprocess `:disk_subprocess_timeout_ms` (20 s) to answer before
  Disk returns its own timeout (#945). A bare `Task.await/1` gives up after 5 s, so on a runner
  that slow to start the helper, the test fails with a `Task.await` exit instead (#1012). A
  `{:filesystem_barrier, ...}` message from `Cinder.Test.BarrierFilesystem` comes only after the
  Disk calls the paused task ran before the pause, and for an `:after` pause also the call it
  pauses after, so a 5 s or 15 s `assert_receive` can fail the test as a missing message instead
  (#1034). The wait here is that bound plus a margin, so one slow start fails the test only
  through Disk's own timeout, and it stays under ExUnit's 60 s per-test timeout.

  `test/code_health/disk_task_await_test.exs` holds both limits. It also fails a `Task.await` or
  `Task.await_many` outside `catch_exit/1` in a test file that names `BarrierFilesystem` or
  `Filesystem.Disk`, so such a file awaits every task here, including one that only writes the
  database. `test/code_health/disk_barrier_wait_test.exs` fails an `assert_receive` of a
  `{:filesystem_barrier, ...}` message in such a file whose timeout is not `timeout_ms/0`,
  including one whose task reaches no subprocess before its pause.
  """

  @margin_ms 10_000

  @doc "Awaits `task` for `timeout_ms/0`."
  def await(%Task{} = task), do: Task.await(task, timeout_ms())

  @doc "The test-env Disk subprocess bound in effect, plus a margin."
  def timeout_ms, do: Application.fetch_env!(:cinder, :disk_subprocess_timeout_ms) + @margin_ms
end
