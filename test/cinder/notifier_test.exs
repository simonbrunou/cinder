defmodule Cinder.NotifierTest do
  use ExUnit.Case, async: false
  import Cinder.ConfigCase
  import ExUnit.CaptureLog

  alias Cinder.Accounts.User
  alias Cinder.Notifier

  test "Log impl logs each event and returns :ok" do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log(fn ->
        assert :ok = Notifier.Log.notify({:movie_available, %{title: "The Matrix"}})
      end)

    assert log =~ "[notifier]"
    assert log =~ "The Matrix"
  end

  test "Log impl sanitizes registration events" do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    email = "kim@example.com"

    log =
      capture_log(fn ->
        assert :ok = Notifier.Log.notify({:user_registered, %{id: 42, email: email}})
      end)

    assert log =~ "[notifier] user_registered user #42"
    refute log =~ email
  end

  test "Log impl formats maintenance outcomes" do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log(fn ->
        assert :ok = Notifier.Log.notify({:maintenance_completed, :scan_tv})
        assert :ok = Notifier.Log.notify({:maintenance_failed, :scan_movies, :unavailable})
      end)

    assert log =~ "maintenance completed: scan_tv"
    assert log =~ "maintenance failed: scan_movies (:unavailable)"
  end

  test "notify/1 dispatches to the configured impl" do
    Cinder.TestNotifier.subscribe()
    assert :ok = Notifier.notify({:movie_failed, %{title: "Dune"}, :boom})
    assert_receive {:notify, {:movie_failed, %{title: "Dune"}, :boom}}
  end

  test "notify/1 never lets a misbehaving impl crash the caller" do
    put_env(:notifier, Cinder.NotifierTest.Raising)

    log =
      capture_log(fn ->
        assert :ok = Notifier.notify({:movie_available, %{title: "X"}})
      end)

    assert log =~ "notifier failed"
  end

  test "notify/1's warning names a failed event by its ids, never the user's email or username" do
    put_env(:notifier, Cinder.NotifierTest.Raising)
    user = %User{id: 7, email: "kim@example.com", plex_username: "kim-plex"}

    log =
      capture_log(fn ->
        assert :ok = Notifier.notify({:sign_in_refused, user, :server_access})
        assert :ok = Notifier.notify({:user_registered, user})
      end)

    assert log =~ "notifier failed for sign_in_refused #7: nope"
    assert log =~ "notifier failed for user_registered user #7: nope"
    refute log =~ "kim"
  end

  defmodule Raising do
    @behaviour Cinder.Notifier
    @impl true
    def notify(_event), do: raise("nope")
  end
end
