defmodule Cinder.Accounts.PlexAuth.SignInProbeTest do
  # async: false — the not-configured case blanks the global Plex token.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase
  import Mox

  alias Cinder.Accounts.PlexAuth.SignInProbe
  alias Cinder.Accounts.PlexAuthMock

  setup :verify_on_exit!

  # config/test.exs: the Plex media server's token.
  @token "test-key"
  @probe [timeouts: :probe]

  defp expect_account(result),
    do: expect(PlexAuthMock, :account, fn @token, @probe -> result end)

  defp expect_machine_id(result),
    do: expect(PlexAuthMock, :server_machine_id, fn @probe -> result end)

  defp expect_resource_ids(result),
    do: expect(PlexAuthMock, :resource_ids, fn @token, @probe -> result end)

  defp owner, do: {:ok, %{id: 1, email: "owner@example.com", username: "owner"}}

  test "passes when plex.tv lists the server for the owner's token, every call bounded" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:ok, ["player-1", "machine-1"]})

    assert SignInProbe.health() == :ok
  end

  test "is not configured without a Plex token, and calls nothing" do
    put_config(Cinder.Library.MediaServer.Plex, token: "")

    assert SignInProbe.health() == {:error, :not_configured}
  end

  test "a 401 or 403 from plex.tv on the account reads :token_rejected" do
    for status <- [401, 403] do
      expect_account({:error, {:plex_tv_status, status}})
      assert SignInProbe.health() == {:error, :token_rejected}, "status #{status}"
    end
  end

  test "an account without an integer id is an unexpected response at :account" do
    for id <- [nil, "1"] do
      expect_account({:ok, %{id: id, email: nil, username: "owner"}})

      assert SignInProbe.health() == {:error, {:account, :unexpected_response}},
             "id #{inspect(id)}"
    end
  end

  test "any other account failure names the :account step" do
    expect_account({:error, {:plex_tv_status, 503}})
    assert SignInProbe.health() == {:error, {:account, {:plex_tv_status, 503}}}
  end

  test "a server_machine_id failure names its step, a 401 from /identity included" do
    expect_account(owner())
    expect_machine_id({:error, %Req.TransportError{reason: :econnrefused}})
    assert SignInProbe.health() == {:error, {:server_machine_id, :econnrefused}}

    # /identity is the local server, not plex.tv: its 401 says nothing about the token.
    expect_account(owner())
    expect_machine_id({:error, {:plex_tv_status, 401}})
    assert SignInProbe.health() == {:error, {:server_machine_id, {:plex_tv_status, 401}}}
  end

  test "a list without the server's machine id reads :server_not_listed" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:ok, ["MACHINE-1", "machine-10"]})

    assert SignInProbe.health() == {:error, :server_not_listed}
  end

  test "a resource-list failure names :server_ids, and its 401 reads :token_rejected" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:error, {:plex_tv_status, 503}})
    assert SignInProbe.health() == {:error, {:server_ids, {:plex_tv_status, 503}}}

    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:error, :unexpected_response})
    assert SignInProbe.health() == {:error, {:server_ids, :unexpected_response}}

    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:error, {:plex_tv_status, 401}})
    assert SignInProbe.health() == {:error, :token_rejected}
  end

  test "an error term that could hold the request keeps only its step" do
    request = %{headers: %{"x-plex-token" => [@token]}}

    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_resource_ids({:error, {:closed, request}})

    assert SignInProbe.health() == {:error, {:server_ids, :error}}
  end

  describe "reason/1" do
    test "keeps a closed set, and gives the same answer twice" do
      for {input, expected} <- [
            {:timeout, :timeout},
            {:not_configured, :not_configured},
            {:server_not_listed, :server_not_listed},
            {:token_rejected, :token_rejected},
            {{:server_access, {:forbidden, 3}}, :server_not_listed},
            {{:account, {:plex_tv_status, 401}}, :token_rejected},
            {{:server_ids, {:plex_tv_status, 403}}, :token_rejected},
            {{:server_machine_id, {:plex_tv_status, 403}},
             {:server_machine_id, {:plex_tv_status, 403}}},
            {{:account, {:plex_tv_status, 502}}, {:account, {:plex_tv_status, 502}}},
            {{:account, :unexpected_response}, {:account, :unexpected_response}},
            {{:server_ids, %Req.TransportError{reason: :timeout}}, {:server_ids, :timeout}},
            {{:server_ids, %{token: @token}}, {:server_ids, :error}},
            {{:account, "x-plex-token: #{@token}"}, {:account, :error}},
            {%RuntimeError{message: @token}, {:exception, RuntimeError}},
            {{:exit, {:noproc, @token}}, :error},
            {@token, :error}
          ] do
        assert SignInProbe.reason(input) == expected, inspect(input)
        assert SignInProbe.reason(expected) == expected, inspect(expected)
        refute inspect(SignInProbe.reason(input)) =~ @token
      end
    end
  end
end
