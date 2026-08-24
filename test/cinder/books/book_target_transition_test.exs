defmodule Cinder.Books.BookTargetTransitionTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog

  test "a guarded transition returns the fresh row and broadcasts exactly once after commit" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :ebook)

    Repo.update_all(
      from(t in BookTarget, where: t.id == ^target.id),
      set: [updated_at: ~U[2000-01-01 00:00:00Z]]
    )

    target = Repo.get!(BookTarget, target.id)
    target_id = target.id
    Books.subscribe_targets()

    assert {:ok,
            %BookTarget{
              status: :monitored,
              updated_at: updated_at
            } = updated} =
             Books.transition_target(target, %{status: :monitored}, expect: :unmonitored)

    assert DateTime.after?(updated_at, target.updated_at)
    assert Repo.get!(BookTarget, target.id) == updated
    assert_receive {:book_target_updated, ^updated}
    refute_receive {:book_target_updated, %BookTarget{id: ^target_id}}
  end

  test "a transition ignores profile assignment attrs" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :ebook)

    assert {:ok, wrong_kind_profile} =
             Catalog.create_profile(%{
               name: "Wrong transition profile #{unique_id()}",
               kind: :audiobook,
               handling: :standard
             })

    assert {:ok, %BookTarget{status: :monitored, profile_id: nil} = updated} =
             Books.transition_target(
               target,
               %{status: :monitored, profile_id: wrong_kind_profile.id},
               expect: :unmonitored
             )

    assert Repo.get!(BookTarget, target.id) == updated
  end

  test "leaving held clears an omitted hold reason" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :ebook)

    assert {:ok, held} =
             Books.transition_target(
               target,
               %{status: :held, hold_reason: "identity conflict"},
               expect: :unmonitored
             )

    assert {:ok, %BookTarget{status: :monitored, hold_reason: nil} = monitored} =
             Books.transition_target(held, %{status: :monitored}, expect: :held)

    assert Repo.get!(BookTarget, target.id) == monitored
  end

  test "hold reason invariants still apply to transitions" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :ebook)

    assert {:error, held_changeset} =
             Books.transition_target(target, %{status: :held}, expect: :unmonitored)

    assert "can't be blank when held" in errors_on(held_changeset).hold_reason

    assert {:error, monitored_changeset} =
             Books.transition_target(
               target,
               %{status: :monitored, hold_reason: "identity conflict"},
               expect: :unmonitored
             )

    assert "must be blank unless held" in errors_on(monitored_changeset).hold_reason
  end

  test "a stale expected status writes nothing and broadcasts nothing" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :audiobook)
    target_id = target.id
    Books.subscribe_targets()

    assert {:ok, monitored} =
             Books.transition_target(target, %{status: :monitored}, expect: :unmonitored)

    assert_receive {:book_target_updated, ^monitored}

    assert {:error, :stale_status} =
             Books.transition_target(
               target,
               %{status: :held, hold_reason: "identity conflict"},
               expect: :unmonitored
             )

    assert Repo.get!(BookTarget, target.id) == monitored
    refute_receive {:book_target_updated, %BookTarget{id: ^target_id}}
  end

  defp work_fixture do
    id = unique_id()

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    work
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
