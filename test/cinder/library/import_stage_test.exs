defmodule Cinder.Library.ImportStageTest do
  use Cinder.DataCase, async: false

  alias Cinder.Library.ImportStage

  defp journal(state, attrs) do
    key = Ecto.UUID.generate()

    {:ok, stage} =
      ImportStage.create(
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

    stage
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

  # The TV park reads it to decide whether a payload may go while files a failed import staged
  # from it could still roll back (#1588).
  test "any_uncommitted?/0 counts each row no catalog write committed" do
    refute ImportStage.any_uncommitted?()

    cases = [
      {:preparing, nil, true},
      {:prepared, nil, true},
      {:rolling_back, :rollback, true},
      {:quarantined, :rollback, true},
      {:quarantined, nil, true},
      {:committed, nil, false},
      {:cleaning, :cleanup, false},
      {:quarantined, :cleanup, false}
    ]

    for {{state, action, uncommitted?}, n} <- Enum.with_index(cases) do
      stage =
        journal(state, %{recovery_action: action, dest: "/tmp/cinder-test-library/M/M#{n}.mkv"})

      assert ImportStage.any_uncommitted?() == uncommitted?,
             "#{state} with recovery_action #{inspect(action)}"

      Repo.delete!(stage)
    end

    journal(:committed, %{dest: "/tmp/cinder-test-library/M/C.mkv"})
    refute ImportStage.any_uncommitted?()
    journal(:preparing, %{dest: "/tmp/cinder-test-library/M/P.mkv"})
    assert ImportStage.any_uncommitted?()
  end
end
