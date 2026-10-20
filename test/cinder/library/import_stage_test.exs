defmodule Cinder.Library.ImportStageTest do
  use Cinder.DataCase, async: false

  alias Cinder.Library.ImportStage

  defp journal(state, attrs) do
    key = Ecto.UUID.generate()

    ImportStage.create!(
      Map.merge(
        %{
          operation_key: key,
          state: state,
          root: "/tmp/cinder-test-library",
          dest: "/tmp/cinder-test-library/M/M.mkv",
          candidate: "/tmp/cinder-test-library/M/candidate-#{key}"
        },
        attrs
      )
    )
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
