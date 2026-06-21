defmodule Cinder.NotifierTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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

  test "notify/1 dispatches to the configured impl" do
    Cinder.TestNotifier.subscribe()
    assert :ok = Notifier.notify({:movie_failed, %{title: "Dune"}, :boom})
    assert_receive {:notify, {:movie_failed, %{title: "Dune"}, :boom}}
  end

  test "notify/1 never lets a misbehaving impl crash the caller" do
    original = Application.fetch_env!(:cinder, :notifier)
    Application.put_env(:cinder, :notifier, Cinder.NotifierTest.Raising)
    on_exit(fn -> Application.put_env(:cinder, :notifier, original) end)

    log =
      capture_log(fn ->
        assert :ok = Notifier.notify({:movie_available, %{title: "X"}})
      end)

    assert log =~ "notifier failed"
  end

  defmodule Raising do
    @behaviour Cinder.Notifier
    @impl true
    def notify(_event), do: raise("nope")
  end
end
