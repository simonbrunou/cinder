defmodule Cinder.GuardedWriteTest do
  use Cinder.DataCase, async: true

  import Cinder.AccountsFixtures

  alias Cinder.Books
  alias Cinder.Books.{BookTarget, BookTargetTransition}
  alias Cinder.GuardedWrite
  alias Cinder.Requests
  alias Cinder.Requests.{Request, RequestTransition}

  describe "write/4 outside a transaction" do
    test "returns the fresh row and publishes it once" do
      target = target_fixture()
      target_id = target.id

      Repo.update_all(from(t in BookTarget, where: t.id == ^target_id),
        set: [updated_at: ~U[2000-01-01 00:00:00Z]]
      )

      target = Repo.get!(BookTarget, target_id)
      Books.subscribe_targets()

      assert {:ok, %BookTarget{status: :monitored} = written} =
               GuardedWrite.write(BookTargetTransition, target, %{status: :monitored},
                 status: :unmonitored
               )

      assert DateTime.after?(written.updated_at, target.updated_at)
      assert Repo.get!(BookTarget, target.id) == written
      assert_receive {:book_target_updated, ^written}
      refute_receive {:book_target_updated, %BookTarget{id: ^target_id}}
    end

    test "a row that moved on is a stale miss that writes and publishes nothing" do
      target = target_fixture()
      target_id = target.id
      Books.subscribe_targets()

      assert {:error, :stale_status} =
               GuardedWrite.write(BookTargetTransition, target, %{status: :monitored},
                 status: {:in, [:held, :available]}
               )

      assert Repo.get!(BookTarget, target.id) == target
      refute_receive {:book_target_updated, %BookTarget{id: ^target_id}}
    end

    test "every named attr is written, even one the caller's row already holds" do
      target = target_fixture()
      {:ok, _moved} = GuardedWrite.write(BookTargetTransition, target, %{status: :monitored})

      # `target` still says :unmonitored, but the row is :monitored: naming the status writes it.
      assert {:ok, %BookTarget{status: :unmonitored}} =
               GuardedWrite.write(BookTargetTransition, target, %{status: :unmonitored})
    end

    # `update_all` skips Ecto's `to_constraints`: the profile-integrity trigger arrives as a raw
    # `Exqlite.Error`, which the adapter names, so the caller gets a refusal instead of a raise.
    test "a constraint the adapter names is a refusal, and the row is untouched" do
      target = target_fixture(:ebook)
      wrong_kind = profile_fixture(:audiobook)

      assert {:error, :invalid_media_profile} =
               GuardedWrite.write(
                 BookTargetTransition,
                 target,
                 %{status: :monitored, profile_id: wrong_kind.id},
                 status: :unmonitored
               )

      assert %BookTarget{status: :unmonitored, profile_id: nil} =
               Repo.get!(BookTarget, target.id)
    end
  end

  describe "transaction/2" do
    test "publishes after commit, once per row, with the row's latest write" do
      target = target_fixture()
      other = target_fixture()
      {target_id, other_id} = {target.id, other.id}
      Books.subscribe_targets()

      assert {:ok, :done} =
               GuardedWrite.transaction(fn ->
                 {:ok, monitored} = write(target, %{status: :monitored})
                 {:ok, _other} = write(other, %{status: :monitored})
                 {:ok, _held} = write(monitored, %{status: :held, hold_reason: "conflict"})
                 refute_received {:book_target_updated, %BookTarget{id: ^target_id}}
                 refute_received {:book_target_updated, %BookTarget{id: ^other_id}}
                 :done
               end)

      assert_received {:book_target_updated, %BookTarget{id: ^target_id, status: :held}}
      assert_received {:book_target_updated, %BookTarget{id: ^other_id, status: :monitored}}
      refute_received {:book_target_updated, %BookTarget{id: ^target_id}}
      refute_received {:book_target_updated, %BookTarget{id: ^other_id}}
    end

    test "a rollback writes and publishes nothing" do
      target = target_fixture()
      target_id = target.id
      Books.subscribe_targets()

      assert {:error, :changed_my_mind} =
               GuardedWrite.transaction(fn ->
                 {:ok, _monitored} = write(target, %{status: :monitored})
                 Repo.rollback(:changed_my_mind)
               end)

      assert Repo.get!(BookTarget, target.id) == target
      refute_received {:book_target_updated, %BookTarget{id: ^target_id}}
    end

    test "a refused write rolls the frame back even when the caller carries on" do
      armed = target_fixture()
      moved_on = target_fixture()
      armed_id = armed.id
      Books.subscribe_targets()

      assert {:error, :stale_status} =
               GuardedWrite.transaction(fn ->
                 {:ok, _armed} = write(armed, %{status: :monitored})
                 {:error, :stale_status} = write(moved_on, %{status: :monitored}, status: :held)
                 :carried_on
               end)

      assert Repo.get!(BookTarget, armed.id) == armed
      refute_received {:book_target_updated, %BookTarget{id: ^armed_id}}
    end

    test "the caller's own rollback reason wins over the refusal" do
      target = target_fixture()

      assert {:error, :stale_grab} =
               GuardedWrite.transaction(fn ->
                 case write(target, %{status: :monitored}, status: :held) do
                   {:ok, written} -> written
                   {:error, _stale} -> Repo.rollback(:stale_grab)
                 end
               end)
    end

    # SQLite's `RAISE(ABORT)` reverts only the aborted statement and leaves the transaction open,
    # so a caller that handled the refusal in place would commit its earlier writes without it.
    test "a constraint refusal rolls back the frame's earlier writes" do
      armed = target_fixture(:ebook)
      refused = target_fixture(:ebook)
      wrong_kind = profile_fixture(:audiobook)

      assert {:error, :invalid_media_profile} =
               GuardedWrite.transaction(fn ->
                 {:ok, _armed} = write(armed, %{status: :monitored})

                 write(refused, %{status: :monitored, profile_id: wrong_kind.id},
                   status: :unmonitored
                 )
               end)

      assert Repo.get!(BookTarget, armed.id) == armed
      assert %BookTarget{profile_id: nil} = Repo.get!(BookTarget, refused.id)
    end

    test "a nested transaction joins the outer frame, which alone publishes" do
      target = target_fixture()
      target_id = target.id
      Books.subscribe_targets()

      assert {:ok, {:ok, %BookTarget{}}} =
               GuardedWrite.transaction(fn ->
                 inner =
                   GuardedWrite.transaction(fn ->
                     {:ok, written} = write(target, %{status: :monitored})
                     written
                   end)

                 refute_received {:book_target_updated, %BookTarget{id: ^target_id}}
                 inner
               end)

      assert_received {:book_target_updated, %BookTarget{id: ^target_id}}
    end

    test "a guarded write inside a raw Repo.transaction raises" do
      target = target_fixture()

      assert_raise ArgumentError, ~r/GuardedWrite.transaction/, fn ->
        Repo.transaction(fn -> write(target, %{status: :monitored}) end)
      end

      assert_raise ArgumentError, ~r/GuardedWrite.transaction/, fn ->
        Repo.transaction(fn -> GuardedWrite.transaction(fn -> :ok end) end)
      end
    end
  end

  describe "the request adapter" do
    # Issue #362's race, at the module: the caller read the profile as an e-book one, another admin
    # re-kinded it before the write, and the `requests_profile_integrity` trigger aborted the
    # write. The refusal names the trigger, so renaming it fails here.
    test "a profile re-kinded after the caller read it is refused, and the frame rolls back" do
      work = work_fixture()
      {:ok, request} = Requests.create_request(user_fixture(), book_request(work))
      {:ok, target} = Books.ensure_target(work, :ebook)
      profile = profile_fixture(:ebook)
      {:ok, _rekinded} = Cinder.Catalog.update_profile(profile, %{kind: :audiobook})

      assert {:error, :invalid_media_profile} =
               GuardedWrite.transaction(fn ->
                 {:ok, _armed} = write(target, %{status: :monitored, profile_id: nil})
                 approve(request, admin_fixture(), profile)
               end)

      assert %Request{status: :pending, proposed_profile_id: nil} = Repo.reload!(request)
      assert %BookTarget{status: :unmonitored} = Repo.reload!(target)
    end

    test "an approver deleted before the write is refused, not raised" do
      {:ok, request} = Requests.create_request(user_fixture(), book_request(work_fixture()))
      approver = admin_fixture()
      {:ok, _user, _token} = Cinder.Accounts.delete_user(admin_fixture(), approver)

      assert {:error, :approver_deleted} = approve(request, approver, profile_fixture(:ebook))
      assert %Request{status: :pending} = Repo.reload!(request)
    end

    test "a constraint the adapter does not name re-raises" do
      user = user_fixture()
      work = work_fixture()
      {:ok, denied} = Requests.create_request(user, book_request(work))
      {:ok, denied} = Requests.deny_request(denied, admin_fixture(), "not now")
      {:ok, _pending} = Requests.create_request(user, book_request(work))

      assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
        GuardedWrite.write(RequestTransition, denied, %{status: :pending}, status: :denied)
      end
    end
  end

  defp approve(request, admin, profile) do
    GuardedWrite.write(
      RequestTransition,
      request,
      %{
        status: :approved,
        approved_by_id: admin.id,
        proposed_profile_id: profile.id,
        proposed_media_profile: profile.handling
      },
      status: :pending
    )
  end

  defp book_request(work), do: %{target_type: "book", target_id: work.id, media_kind: :ebook}

  defp write(target, attrs, expect \\ []),
    do: GuardedWrite.write(BookTargetTransition, target, attrs, expect)

  defp profile_fixture(kind) do
    {:ok, profile} =
      Cinder.Catalog.create_profile(%{
        name: "#{kind} #{System.unique_integer([:positive])}",
        kind: kind,
        handling: :standard
      })

    profile
  end

  defp target_fixture(media_kind \\ :ebook) do
    {:ok, target} = Books.ensure_target(work_fixture(), media_kind)
    target
  end

  defp work_fixture do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    work
  end
end
