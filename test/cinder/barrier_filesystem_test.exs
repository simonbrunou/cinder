defmodule Cinder.Test.BarrierFilesystemTest do
  # `fail_once/1` and `fail_in_order/1` point the app-wide `:filesystem` key at
  # `BarrierFilesystem`, and the test's exit puts back the value it held before (#1060). Each test
  # registers its check with `on_exit/1` before it arms. ExUnit runs `on_exit` callbacks
  # last-registered first, so the check runs after the helper's own callback. Each test fires its
  # failure through `BarrierFilesystem.lstat/1`, which returns an injected failure before it
  # reaches `Disk`. The module is sync because it changes `:filesystem` for every process.
  use ExUnit.Case, async: false

  alias Cinder.Test.BarrierFilesystem

  @lstat_failure %{operation: :lstat, source_contains: "barrier-restore", reason: :eio}

  # Each test starts from the mock, whatever an earlier test left, so a helper that never restores
  # fails every test here in any order.
  setup do
    Cinder.ConfigCase.put_env(:filesystem, Cinder.Library.FilesystemMock)
    {:ok, filesystem: Cinder.Library.FilesystemMock}
  end

  test "fail_once/1 keeps :filesystem on BarrierFilesystem until the test exits, then restores it",
       %{filesystem: filesystem} do
    on_exit(fn -> assert Application.fetch_env!(:cinder, :filesystem) == filesystem end)

    BarrierFilesystem.fail_once(@lstat_failure)

    assert BarrierFilesystem.lstat("/nowhere/barrier-restore") == {:error, :eio}
    assert Application.fetch_env!(:cinder, :filesystem) == BarrierFilesystem
  end

  test "fail_in_order/1 keeps :filesystem on BarrierFilesystem until the test exits, then restores it",
       %{filesystem: filesystem} do
    on_exit(fn -> assert Application.fetch_env!(:cinder, :filesystem) == filesystem end)

    BarrierFilesystem.fail_in_order([@lstat_failure])

    assert BarrierFilesystem.lstat("/nowhere/barrier-restore") == {:error, :eio}
    assert Application.fetch_env!(:cinder, :filesystem) == BarrierFilesystem
  end

  # The second arm finds `:filesystem` already on BarrierFilesystem, and its callback puts that
  # back before the first arm's callback restores the value from before both.
  test "two arms in one test unwind to the value before the first", %{filesystem: filesystem} do
    on_exit(fn -> assert Application.fetch_env!(:cinder, :filesystem) == filesystem end)

    BarrierFilesystem.fail_once(@lstat_failure)
    assert BarrierFilesystem.lstat("/nowhere/barrier-restore") == {:error, :eio}

    on_exit(fn ->
      assert Application.fetch_env!(:cinder, :filesystem) == BarrierFilesystem
    end)

    BarrierFilesystem.fail_in_order([@lstat_failure])
    assert BarrierFilesystem.lstat("/nowhere/barrier-restore") == {:error, :eio}
  end

  # The setup's restore runs after every callback here and puts the mock back.
  test "the exit deletes :filesystem when it was unset before arming" do
    Application.delete_env(:cinder, :filesystem)
    on_exit(fn -> assert Application.fetch_env(:cinder, :filesystem) == :error end)

    BarrierFilesystem.fail_once(@lstat_failure)

    assert BarrierFilesystem.lstat("/nowhere/barrier-restore") == {:error, :eio}
  end

  # A failure that never fires fails the test that armed it, so this test arms from a child that
  # stands in for a test process: it registers itself with `ExUnit.OnExitHandler`, the module
  # ExUnit keeps each test's `on_exit` callbacks in. `OnExitHandler.run/2` then runs the child's
  # callbacks as ExUnit runs a test's, and returns the failure instead of failing this test. The
  # test's own pid is never registered: that would drop the callbacks this test registered.
  test "the exit restores :filesystem even when the failure never fired", %{
    filesystem: filesystem
  } do
    # Clears the failure if the child dies before its callbacks run.
    on_exit(fn -> Application.delete_env(:cinder, :filesystem_failure) end)

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         ExUnit.OnExitHandler.register(self())
         BarrierFilesystem.fail_once(@lstat_failure)
         result = ExUnit.OnExitHandler.run(self(), 5_000)

         send(
           parent,
           {:exited, result, Application.fetch_env(:cinder, :filesystem),
            Application.fetch_env(:cinder, :filesystem_failure)}
         )
       end},
      id: make_ref()
    )

    assert_receive {:exited, {:error, %ExUnit.AssertionError{message: message}, _stacktrace},
                    restored, failure}

    assert message =~ "an injected filesystem failure never fired"
    assert restored == {:ok, filesystem}
    assert failure == :error
  end
end
