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

  # DBConnection takes the connection back from an owner that held it past `ownership_timeout`,
  # 120 s by default, so a sync test tagged a longer `timeout` failed at 120 s (#1276). These
  # cases read the options both checkout paths of `setup_sandbox/1` pass.
  describe "checkout_opts/1 gives a sync test an ownership_timeout" do
    for {path, path_tags, path_opts} <- [
          {"boxed", %{}, [shared: true]},
          {"unboxed", %{unboxed: true}, [sandbox: false]}
        ] do
      @path_tags path_tags
      @path_opts path_opts

      test "of 120 s on the #{path} path when the test has no timeout tag" do
        # ExUnit puts `timeout: nil` in the tags of a test with no tag.
        assert DataCase.checkout_opts(Map.merge(@path_tags, %{async: false, timeout: nil})) ==
                 @path_opts ++ [ownership_timeout: 120_000]
      end

      test "of 120 s on the #{path} path when the test is tagged 120 s or less" do
        for timeout <- [1, 60_000, 120_000] do
          tags = Map.merge(@path_tags, %{async: false, timeout: timeout})
          assert DataCase.checkout_opts(tags) == @path_opts ++ [ownership_timeout: 120_000]
        end
      end

      test "of the tag on the #{path} path when the test is tagged above 120 s" do
        for timeout <- [120_001, 300_000] do
          tags = Map.merge(@path_tags, %{async: false, timeout: timeout})
          assert DataCase.checkout_opts(tags) == @path_opts ++ [ownership_timeout: timeout]
        end
      end

      test "of :infinity on the #{path} path when the test is tagged timeout: :infinity" do
        tags = Map.merge(@path_tags, %{async: false, timeout: :infinity})
        assert DataCase.checkout_opts(tags) == @path_opts ++ [ownership_timeout: :infinity]
      end
    end

    test "and still shares the boxed connection only for a test that is not async" do
      assert DataCase.checkout_opts(%{async: true, timeout: nil}) ==
               [shared: false, ownership_timeout: 120_000]
    end
  end
end
