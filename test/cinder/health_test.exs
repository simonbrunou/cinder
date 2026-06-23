defmodule Cinder.HealthTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "check_all/0 returns labeled rows for indexer, download clients, media server, libraries" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    assert [
             %{label: "Indexer (IndexerMock)", status: :ok},
             %{label: "Download (torrent · ClientMock)", status: {:error, :econnrefused}},
             %{label: "Download (usenet · SabnzbdClientMock)", status: :ok},
             %{label: "Media server (MediaServerMock)", status: :ok},
             %{label: "Library (movies)", status: :ok},
             %{label: "Library (tv)", status: :ok}
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

  test "check_service({:library, :movies}) is :ok when the library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service({:library, :movies}) == :ok
  end

  test "check_service({:library, :movies}) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service({:library, :movies}) == {:error, :eacces}
  end

  test "check_service({:library, :tv}) is :ok when the TV library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service({:library, :tv}) == :ok
  end

  test "check_service({:library, :tv}) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service({:library, :tv}) == {:error, :eacces}
  end
end
