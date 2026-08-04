defmodule CinderWeb.TelemetryTest do
  use ExUnit.Case, async: false

  alias CinderWeb.Telemetry

  @tag :tmp_dir
  test "disk measurements use the configured prober seam", %{tmp_dir: tmp} do
    saved =
      Map.new([:movies_library_path, :tv_library_path, :disk_stats_stub], fn key ->
        {key, Application.fetch_env(:cinder, key)}
      end)

    handler_id = "telemetry-disk-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:cinder, :disk],
        fn event, measurements, metadata, pid ->
          send(pid, {:disk_event, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(saved)
    end)

    Application.put_env(:cinder, :movies_library_path, tmp)
    Application.delete_env(:cinder, :tv_library_path)

    Application.put_env(:cinder, :disk_stats_stub, fn path ->
      send(test_pid, {:stub_called, path})
      {:error, :stubbed}
    end)

    assert :ok = Telemetry.dispatch_disk_measurements()
    assert_receive {:stub_called, ^tmp}
    refute_receive {:disk_event, [:cinder, :disk], _measurements, _metadata}, 20
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {key, {:ok, value}} -> Application.put_env(:cinder, key, value)
      {key, :error} -> Application.delete_env(:cinder, key)
    end)
  end
end
