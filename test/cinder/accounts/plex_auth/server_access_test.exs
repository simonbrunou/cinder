defmodule Cinder.Accounts.PlexAuth.ServerAccessTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.PlexAuthMock

  setup :verify_on_exit!

  defp expect_machine_id(result, opts \\ []),
    do: expect(PlexAuthMock, :server_machine_id, fn ^opts -> result end)

  defp expect_resource_ids(result, opts \\ []),
    do: expect(PlexAuthMock, :resource_ids, fn "token", ^opts -> result end)

  test "admits a token whose list holds the server's exact machine id" do
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:ok, ["player-1", "machine-1"]})

    assert PlexAuth.server_access("token") == :ok
  end

  test "refuses a near miss or an empty list, counting the ids the list held" do
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:ok, ["MACHINE-1", "machine-10", "machine-1 "]})
    assert PlexAuth.server_access("token") == {:error, {:server_access, {:forbidden, 3}}}

    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:ok, []})
    assert PlexAuth.server_access("token") == {:error, {:server_access, {:forbidden, 0}}}
  end

  test "a machine id failure names its step and asks plex.tv nothing" do
    expect_machine_id({:error, :unexpected_response})
    assert PlexAuth.server_access("token") == {:error, {:server_machine_id, :unexpected_response}}
  end

  test "a resource-list failure names its step" do
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:error, {:plex_tv_status, 503}})
    assert PlexAuth.server_access("token") == {:error, {:server_ids, {:plex_tv_status, 503}}}
  end

  test "passes its options to both calls" do
    expect_machine_id({:ok, "machine-1"}, timeouts: :probe)
    expect_resource_ids({:ok, ["machine-1"]}, timeouts: :probe)

    assert PlexAuth.server_access("token", timeouts: :probe) == :ok
  end
end
