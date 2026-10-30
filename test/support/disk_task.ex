defmodule Cinder.Test.DiskTask do
  @moduledoc """
  Awaits a test's task that can reach a `Cinder.Library.Filesystem.Disk` subprocess: the rooted
  helper or a bounded command such as the directory sync.

  `config/test.exs` gives such a subprocess `:disk_subprocess_timeout_ms` (20 s) to answer before
  Disk returns its own timeout (#945). A bare `Task.await/1` gives up after 5 s, so on a runner
  that slow to start the helper, the test fails with a `Task.await` exit instead (#1012). The
  wait here is that bound plus a margin, so one slow start fails the test only through Disk's
  own timeout, and it stays under ExUnit's 60 s per-test timeout.

  `test/code_health/disk_task_await_test.exs` holds both limits. It also fails a `Task.await` or
  `Task.await_many` outside `catch_exit/1` in a test file that names `BarrierFilesystem` or
  `Filesystem.Disk`, so such a file awaits every task here, including one that only writes the
  database.
  """

  @margin_ms 10_000

  @doc "Awaits `task` for `timeout_ms/0`."
  def await(%Task{} = task), do: Task.await(task, timeout_ms())

  @doc "The test-env Disk subprocess bound in effect, plus a margin."
  def timeout_ms, do: Application.fetch_env!(:cinder, :disk_subprocess_timeout_ms) + @margin_ms
end
