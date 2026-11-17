defmodule Cinder.Accounts.PlexAuth.ServerAccessTest do
  # async: false — the not-configured case blanks the global Plex token.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase
  import Mox

  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.PlexAuthMock

  setup :verify_on_exit!

  # config/test.exs: the Plex media server's token, which belongs to the server's owner.
  @owner_token "test-key"
  @owner_id 1

  defp expect_owner(result \\ {:ok, %{id: @owner_id, email: nil, username: "owner"}}, opts \\ []),
    do: expect(PlexAuthMock, :account, fn @owner_token, ^opts -> result end)

  defp expect_machine_id(result, opts \\ []),
    do: expect(PlexAuthMock, :server_machine_id, fn ^opts -> result end)

  defp expect_share_ids(result, opts \\ []),
    do: expect(PlexAuthMock, :server_share_ids, fn @owner_token, "machine-1", ^opts -> result end)

  test "admits the owner's account without reading the share list" do
    expect_owner()
    assert PlexAuth.server_access(@owner_id) == :ok
  end

  test "admits an account on the share list, read with the owner's token" do
    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, [7, 9, 12]})

    assert PlexAuth.server_access(9) == :ok
  end

  test "refuses an account on neither list, counting the ids the share list held" do
    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, [7, 90, 12]})
    assert PlexAuth.server_access(9) == {:error, {:server_access, {:forbidden, 3}}}

    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, []})
    assert PlexAuth.server_access(9) == {:error, {:server_access, {:forbidden, 0}}}
  end

  test "an id that is not an integer is never admitted, as the owner or from the list" do
    for plex_id <- [nil, "1", "9", 1.0, 9.0] do
      expect_owner()
      expect_machine_id({:ok, "machine-1"})
      expect_share_ids({:ok, [9]})

      assert PlexAuth.server_access(plex_id) == {:error, {:server_access, {:forbidden, 1}}},
             "plex_id #{inspect(plex_id)}"
    end

    # The same value on the list, should an impl ever return one, admits nobody either.
    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, [nil, "9"]})
    assert PlexAuth.server_access(nil) == {:error, {:server_access, {:forbidden, 2}}}

    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, [nil, "9"]})
    assert PlexAuth.server_access("9") == {:error, {:server_access, {:forbidden, 2}}}
  end

  test "an owner account without a positive integer id refuses at :owner_account" do
    for id <- [nil, "1", 0, -1, 1.0] do
      expect_owner({:ok, %{id: id, email: nil, username: "owner"}})

      assert PlexAuth.server_access(id) == {:error, {:owner_account, :unexpected_response}},
             "owner id #{inspect(id)}"
    end
  end

  test "an owner account failure names :owner_account and reads nothing else" do
    expect_owner({:error, {:plex_tv_status, 401}})
    assert PlexAuth.server_access(9) == {:error, {:owner_account, {:plex_tv_status, 401}}}
  end

  test "a blank owner token refuses at :owner_account and calls nothing" do
    put_config(Cinder.Library.MediaServer.Plex, token: "")

    assert PlexAuth.server_access(@owner_id) == {:error, {:owner_account, :not_configured}}
    assert PlexAuth.share_ids() == {:error, {:server_shares, :not_configured}}
  end

  test "a machine id failure names its step and asks plex.tv for no share list" do
    expect_owner()
    expect_machine_id({:error, :unexpected_response})
    assert PlexAuth.server_access(9) == {:error, {:server_machine_id, :unexpected_response}}
  end

  test "a share-list failure names :server_shares" do
    expect_owner()
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:error, {:plex_tv_status, 503}})
    assert PlexAuth.server_access(9) == {:error, {:server_shares, {:plex_tv_status, 503}}}
  end

  test "passes its options to every call" do
    expect_owner({:ok, %{id: @owner_id, email: nil, username: "owner"}}, timeouts: :probe)
    expect_machine_id({:ok, "machine-1"}, timeouts: :probe)
    expect_share_ids({:ok, [9]}, timeouts: :probe)

    assert PlexAuth.server_access(9, timeouts: :probe) == :ok
  end
end
