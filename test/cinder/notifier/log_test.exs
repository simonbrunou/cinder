defmodule Cinder.Notifier.LogTest do
  # async: false — bumps Logger to :info (the suite default is :warning) to see Log's output.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Notifier.Log

  setup do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    :ok
  end

  test "account_activated logs the user id, never their email" do
    log =
      capture_log(fn ->
        assert :ok = Log.notify({:account_activated, %{id: 7, email: "kim@example.com"}})
      end)

    assert log =~ "[notifier] account activated: user #7"
    refute log =~ "kim@example.com"
  end
end
