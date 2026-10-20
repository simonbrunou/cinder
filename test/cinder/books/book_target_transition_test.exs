defmodule Cinder.Books.BookTargetTransitionTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog

  # A transition carries `profile_id` so an approval can arm a target and attach its profile in
  # one guarded write. `monitor_target/3` refuses the wrong kind before the write; the DB fence
  # behind it is tested at `Cinder.GuardedWrite` (test/cinder/guarded_write_test.exs).
  test "a wrong-kind profile is refused before the write" do
    work = work_fixture()
    {:ok, target} = Books.ensure_target(work, :ebook)

    assert {:ok, wrong_kind_profile} =
             Catalog.create_profile(%{
               name: "Wrong transition profile #{unique_id()}",
               kind: :audiobook,
               handling: :standard
             })

    assert {:error, :invalid_media_profile} =
             Books.monitor_target(work, :ebook, wrong_kind_profile)

    assert %BookTarget{status: :unmonitored, profile_id: nil} = Repo.get!(BookTarget, target.id)
  end

  test "monitor_target arms an unmonitored target and attaches its profile" do
    work = work_fixture()

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Ebook transition profile #{unique_id()}",
               kind: :ebook,
               handling: :standard
             })

    Books.subscribe_targets()

    assert {:ok, %BookTarget{status: :monitored, profile_id: profile_id} = armed} =
             Books.monitor_target(work, :ebook, profile)

    assert profile_id == profile.id
    assert_receive {:book_target_updated, ^armed}
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
