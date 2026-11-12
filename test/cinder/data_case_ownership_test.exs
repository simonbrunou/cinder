defmodule Cinder.DataCaseOwnershipTest do
  # `Cinder.DataCase.setup_sandbox/1` checks the connection out with `checkout_opts/1` on both
  # paths, so the owner keeps it for as long as the test's `timeout` tag (#1276). DataCaseTest
  # reads the options `checkout_opts/1` returns. These tests show each checkout passes them on:
  # with the floor `checkout_opts/1` reads from `Cinder.Repo`'s config set to 100 ms, the owner
  # loses its connection within seconds. A checkout that dropped the options would keep
  # DBConnection's 120 s default.
  #
  # The module is sync and not a DataCase: it checks out the pool's one connection itself, and
  # the lapse disconnects that connection.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.DataCase
  alias Cinder.Repo

  @floor_ms 100
  # 100 polls 50 ms apart: a connection still owned after 5 s fails the test.
  @polls 100

  setup do
    config = Application.fetch_env!(:cinder, Repo)
    Application.put_env(:cinder, Repo, Keyword.put(config, :ownership_timeout, @floor_ms))
    on_exit(fn -> Application.put_env(:cinder, Repo, config) end)
  end

  test "the boxed checkout takes its ownership_timeout from checkout_opts/1" do
    tags = %{async: false, timeout: nil}
    assert DataCase.checkout_opts(tags)[:ownership_timeout] == @floor_ms

    capture_log(fn ->
      DataCase.setup_sandbox(tags)
      assert_ownership_lapses()
    end)
  end

  test "the unboxed checkout takes its ownership_timeout from checkout_opts/1" do
    tags = %{async: false, unboxed: true, timeout: nil}
    assert DataCase.checkout_opts(tags)[:ownership_timeout] == @floor_ms

    capture_log(fn ->
      DataCase.setup_sandbox(tags)
      assert_ownership_lapses()
    end)
  end

  # A query after the lapse raises `OwnershipError`. A query that meets the lapse fails in one of
  # three other ways: it raises a `ConnectionError` when the lapse closes the connection
  # mid-query, it exits with the `ConnectionError` that names the lapse when it reaches the
  # ownership proxy as it stops, or it exits `:noproc` when it reaches a proxy that has just
  # stopped. The last one failed 1 run in 1000 before this clause existed. A connection that
  # never lapses meets none of them.
  defp assert_ownership_lapses do
    Enum.reduce_while(1..@polls, :owned, fn _poll, :owned ->
      try do
        Repo.query!("SELECT 1")
        Process.sleep(50)
        {:cont, :owned}
      rescue
        DBConnection.OwnershipError -> {:halt, :lapsed}
        DBConnection.ConnectionError -> {:halt, :lapsed}
      catch
        :exit, {{:shutdown, %DBConnection.ConnectionError{message: message}}, _call} ->
          assert message =~ "owned the connection for longer than #{@floor_ms}ms"
          {:halt, :lapsed}

        :exit, {:noproc, {DBConnection.Holder, :checkout, _args}} ->
          {:halt, :lapsed}
      end
    end)
    |> case do
      :lapsed ->
        :ok

      :owned ->
        flunk("the owner kept its connection past 5 s, so the checkout dropped ownership_timeout")
    end
  end
end
