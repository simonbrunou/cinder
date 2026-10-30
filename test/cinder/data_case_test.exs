defmodule Cinder.DataCaseTest do
  # An async test's checkout queues for the test pool's one connection, and DBConnection drops it
  # once it has queued past 2 x queue_target. `setup_sandbox/1` refuses an async test whose
  # `timeout` tag would outlast that drop (#1021).
  #
  # This module is itself an async DataCase, so this test process holds the one connection while
  # it runs. A refusal that came after a checkout would queue behind that connection instead of
  # raising, so a prompt `ArgumentError` shows the check runs first. On the `unboxed: true` path,
  # a checkout from this process returns `{:already, :allowed}` and fails with a `MatchError`. The
  # passing cases call `check_timeout_tag!/1`: through `setup_sandbox/1` they would start a
  # second owner that waits for this test's connection.
  use Cinder.DataCase, async: true

  alias Cinder.DataCase

  defp bound, do: 2 * Application.get_env(:cinder, Cinder.Repo)[:queue_target]

  describe "setup_sandbox/1 raises before any checkout" do
    test "for an async test tagged one millisecond past 2 x queue_target" do
      assert_raise ArgumentError, ~r/queue_target/, fn ->
        DataCase.setup_sandbox(%{async: true, timeout: bound() + 1})
      end
    end

    test "for an async test tagged timeout: :infinity" do
      assert_raise ArgumentError, ~r/queue_target/, fn ->
        DataCase.setup_sandbox(%{async: true, timeout: :infinity})
      end
    end

    test "for an unboxed async test tagged one millisecond past 2 x queue_target" do
      assert_raise ArgumentError, ~r/queue_target/, fn ->
        DataCase.setup_sandbox(%{async: true, unboxed: true, timeout: bound() + 1})
      end
    end

    test "with a message naming the tagged timeout, the bound and async: false" do
      error =
        assert_raise ArgumentError, fn ->
          DataCase.setup_sandbox(%{async: true, timeout: bound() + 1})
        end

      assert error.message =~ "timeout: #{bound() + 1}"
      assert error.message =~ "at #{bound()} ms"
      assert error.message =~ "async: false"
    end
  end

  describe "check_timeout_tag!/1 passes" do
    test "an async test with no timeout tag" do
      assert DataCase.check_timeout_tag!(%{async: true}) == :ok
    end

    test "an async test tagged exactly 2 x queue_target" do
      assert DataCase.check_timeout_tag!(%{async: true, timeout: bound()}) == :ok
    end

    test "a sync test tagged one millisecond past 2 x queue_target" do
      assert DataCase.check_timeout_tag!(%{async: false, timeout: bound() + 1}) == :ok
    end
  end
end
