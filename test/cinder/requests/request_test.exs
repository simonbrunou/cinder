defmodule Cinder.Requests.RequestTest do
  use Cinder.DataCase, async: true
  alias Cinder.Requests.Request

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
end
