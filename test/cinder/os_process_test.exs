defmodule Cinder.Test.OsProcessTest do
  # `await_record/1` is how the kill tests of `Cinder.DiskTest`,
  # `Cinder.Library.MediaInfo.FfprobeTest` and `Cinder.Subtitles.Sync.FfsubsyncTest` tell a stub
  # that left no record from one that recorded (#1401). No subprocess writes a record here: a test
  # writes the file itself, or writes no record.
  use ExUnit.Case, async: true

  alias Cinder.Test.OsProcess

  @moduletag :tmp_dir

  test "await_record/1 returns a record written during the wait", %{tmp_dir: tmp} do
    path = Path.join(tmp, "stub.pid")
    write_later(path, "4242\n", 200)

    assert OsProcess.await_record(path) == {:ok, "4242\n"}
  end

  test "await_record/1 reads an empty file as no record until the stub writes it", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "stub.pid")
    File.write!(path, "")
    write_later(path, "4242\n", 200)

    assert OsProcess.await_record(path) == {:ok, "4242\n"}
  end

  test "await_record/1 returns :none after 1 s when no file appears", %{tmp_dir: tmp} do
    {elapsed, result} = timed(fn -> OsProcess.await_record(Path.join(tmp, "stub.pid")) end)

    assert result == :none
    assert elapsed >= 1_000
    assert elapsed < 5_000
  end

  test "await_record/1 returns :none after 1 s when the file stays empty", %{tmp_dir: tmp} do
    path = Path.join(tmp, "stub.pid")
    File.write!(path, "")

    {elapsed, result} = timed(fn -> OsProcess.await_record(path) end)

    assert result == :none
    assert elapsed >= 1_000
    assert elapsed < 5_000
  end

  defp write_later(path, contents, ms) do
    start_supervised!(
      {Task,
       fn ->
         Process.sleep(ms)
         File.write!(path, contents)
       end}
    )
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - t0, result}
  end
end
