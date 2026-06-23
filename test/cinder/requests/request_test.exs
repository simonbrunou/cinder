defmodule Cinder.Requests.RequestTest do
  use Cinder.DataCase, async: true
  alias Cinder.Requests.Request
  import Cinder.AccountsFixtures

  test "create_changeset casts a season request and accepts target_type \"season\"" do
    cs =
      Request.create_changeset(%Request{}, %{
        user_id: 1,
        target_type: "season",
        target_id: 1399,
        season_number: 2,
        title: "Game of Thrones",
        status: :pending
      })

    assert cs.valid?
    assert get_field(cs, :season_number) == 2
  end

  test "create_changeset rejects an unknown target_type" do
    cs =
      Request.create_changeset(%Request{}, %{
        user_id: 1,
        target_type: "bogus",
        target_id: 1,
        status: :pending
      })

    refute cs.valid?
    assert %{target_type: _} = errors_on(cs)
  end

  # ── Season dedup: unique index covers (user_id, target_type, target_id, season_number) ──

  defp season_attrs(user_id) do
    %{
      user_id: user_id,
      target_type: "season",
      target_id: 1399,
      season_number: 2,
      title: "Game of Thrones",
      status: :pending
    }
  end

  test "duplicate pending season request returns {:error, changeset} — not a raise" do
    user = user_fixture()
    attrs = season_attrs(user.id)

    assert {:ok, _} =
             %Request{}
             |> Request.create_changeset(attrs)
             |> Repo.insert()

    # Second identical pending insert must return a changeset error, not raise
    assert {:error, %Ecto.Changeset{}} =
             %Request{}
             |> Request.create_changeset(attrs)
             |> Repo.insert()
  end

  test "two pending requests for same series but different season_number both succeed" do
    user = user_fixture()
    attrs = season_attrs(user.id)

    assert {:ok, _} =
             %Request{}
             |> Request.create_changeset(attrs)
             |> Repo.insert()

    assert {:ok, _} =
             %Request{}
             |> Request.create_changeset(Map.put(attrs, :season_number, 3))
             |> Repo.insert()
  end

  test "a denied season request does not block a fresh pending request for the same season" do
    user = user_fixture()
    attrs = season_attrs(user.id)

    assert {:ok, req} =
             %Request{}
             |> Request.create_changeset(attrs)
             |> Repo.insert()

    # Transition to denied
    assert {:ok, _} =
             req
             |> Request.status_changeset(%{status: :denied, denial_reason: "not now"})
             |> Repo.update()

    # A new pending request for the same (user, target_type, target_id, season_number) must succeed
    assert {:ok, %{status: :pending}} =
             %Request{}
             |> Request.create_changeset(attrs)
             |> Repo.insert()
  end
end
