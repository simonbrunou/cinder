defmodule Cinder.HealthTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "check_all/0 returns labeled rows for indexer, both download clients, and media server" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    assert [
             %{label: "Indexer (IndexerMock)", status: :ok},
             %{label: "Download (torrent · ClientMock)", status: {:error, :econnrefused}},
             %{label: "Download (usenet · SabnzbdClientMock)", status: :ok},
             %{label: "Media server (MediaServerMock)", status: :ok}
           ] = Cinder.Health.check_all()
  end

  test "check_all/0 turns a raising impl into an error row instead of crashing" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> raise "boom" end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    rows = Cinder.Health.check_all()
    indexer = Enum.find(rows, &(&1.label =~ "Indexer"))

    assert {:error, %RuntimeError{message: "boom"}} = indexer.status
  end

  test "check_all/0 turns an exiting impl into an error row instead of crashing the task" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> exit(:boom) end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    rows = Cinder.Health.check_all()
    indexer = Enum.find(rows, &(&1.label =~ "Indexer"))

    assert {:error, {:exit, :boom}} = indexer.status
  end

  test "check_service(:library) is :ok when the library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service(:library) == :ok
  end

  test "check_service(:library) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service(:library) == {:error, :eacces}
  end

  test "check_service(:tv_library) is :ok when the TV library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service(:tv_library) == :ok
  end

  test "check_service(:tv_library) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service(:tv_library) == {:error, :eacces}
  end
end
