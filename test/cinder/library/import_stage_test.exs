defmodule Cinder.Library.ImportStageTest do
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.Movie
  alias Cinder.Library
  alias Cinder.Library.ImportStage

  setup :verify_on_exit!

  defp journal(state, attrs \\ %{}) do
    key = Ecto.UUID.generate()

    ImportStage.create!(
      Map.merge(
        %{
          operation_key: key,
          state: state,
          root: "/tmp/cinder-test-library",
          dest: "/tmp/cinder-test-library/M/M.mkv",
          candidate: "/tmp/cinder-test-library/M/.cinder-stage-#{key}"
        },
        attrs
      )
    )
  end

  defp token(id, key) do
    %{
      dest: "/tmp/cinder-test-library/M/M.mkv",
      quality: %{sidecar_subtitles: []},
      rollback: %{
        state: :durable,
        stage_id: id,
        operation_key: key,
        after_commit: {:movie, %Movie{title: "M", tmdb_id: 1}},
        folder?: false,
        source: "/downloads/M.mkv"
      }
    }
  end

  defp scan_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies ->
      Agent.update(counter, &(&1 + 1))
      :ok
    end)

    counter
  end

  test "commit_stage runs no effects when the journal row is missing" do
    counter = scan_counter()

    assert :ok = Library.commit_stage(token(-1, "missing"))
    assert Agent.get(counter, & &1) == 0
  end

  test "commit_stage runs no effects for an uncommitted journal row" do
    counter = scan_counter()
    stage = journal(:prepared)

    assert {:error, :import_stage_not_committed} =
             Library.commit_stage(token(stage.id, stage.operation_key))

    assert Agent.get(counter, & &1) == 0
  end

  test "commit_stage claims post-commit effects only once" do
    counter = scan_counter()
    stage = journal(:committed)
    token = token(stage.id, stage.operation_key)

    assert :ok = Library.commit_stage(token)
    assert :ok = Library.commit_stage(token)
    assert Agent.get(counter, & &1) == 1
  end

  test "a committed cleanup error still permits effects exactly once" do
    counter = scan_counter()

    stage =
      journal(:committed, %{
        backup: "/tmp/cinder-test-library/M/.cinder-rollback-error",
        backup_inode: 4,
        backup_device: 5,
        backup_size: 6
      })

    stub(Cinder.Library.FilesystemMock, :lstat, fn _path -> {:error, :eacces} end)
    token = token(stage.id, stage.operation_key)

    log = capture_log(fn -> assert {:error, :eacces} = Library.commit_stage(token) end)

    assert log =~ "import stage #{stage.id} cleanup pending: eacces"
    assert :ok = Library.commit_stage(token)
    assert Agent.get(counter, & &1) == 1
  end

  test "operators can inspect and safely retry a quarantined rollback" do
    stage =
      journal(:quarantined, %{
        recovery_action: :rollback,
        attempt_count: 8,
        last_error: "eacces",
        backup: "/tmp/cinder-test-library/M/.cinder-rollback-owned"
      })

    assert [%ImportStage{id: id}] = Cinder.Library.quarantined_import_stages()
    assert id == stage.id
    assert {:ok, retried} = Cinder.Library.retry_import_stage(stage.id)
    assert retried.state == :rolling_back
    assert retried.recovery_action == :rollback
    assert retried.attempt_count == 0
    assert retried.last_error == nil
    assert retried.backup == stage.backup
    assert DateTime.compare(retried.next_attempt_at, DateTime.utc_now()) in [:lt, :eq]
  end

  test "operator retry preserves the cleanup direction" do
    stage =
      journal(:quarantined, %{
        recovery_action: :cleanup,
        attempt_count: 8,
        last_error: "eacces"
      })

    assert {:ok, retried} = Cinder.Library.retry_import_stage(stage.id)
    assert retried.state == :cleaning
    assert retried.recovery_action == :cleanup
  end
end
