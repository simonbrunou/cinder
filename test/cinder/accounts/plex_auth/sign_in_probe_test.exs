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

  defp expect_share_ids(result),
    do: expect(PlexAuthMock, :server_share_ids, fn @token, "machine-1", @probe -> result end)

  defp owner, do: {:ok, %{id: 1, email: "owner@example.com", username: "owner"}}

  test "passes when plex.tv returns the owner's account and the share list, every call bounded" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, [7, 9]})

    assert SignInProbe.health() == :ok
  end

  # The gate admits the owner without the list, so the check reads it on its own.
  test "reads the share list though the owner's own sign-in would not, and an empty list passes" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:ok, []})

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

  test "an account without a positive integer id is an unexpected response at :owner_account" do
    for id <- [nil, "1", 0] do
      expect_account({:ok, %{id: id, email: nil, username: "owner"}})

      assert SignInProbe.health() == {:error, {:owner_account, :unexpected_response}},
             "id #{inspect(id)}"
    end
  end

  test "any other account failure names the :owner_account step" do
    expect_account({:error, {:plex_tv_status, 503}})
    assert SignInProbe.health() == {:error, {:owner_account, {:plex_tv_status, 503}}}
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

  test "a share-list failure names :server_shares, and its 401 or 403 reads :token_rejected" do
    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:error, {:plex_tv_status, 503}})
    assert SignInProbe.health() == {:error, {:server_shares, {:plex_tv_status, 503}}}

    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:error, :unexpected_response})
    assert SignInProbe.health() == {:error, {:server_shares, :unexpected_response}}

    for status <- [401, 403] do
      expect_account(owner())
      expect_machine_id({:ok, "machine-1"})
      expect_share_ids({:error, {:plex_tv_status, status}})
      assert SignInProbe.health() == {:error, :token_rejected}, "status #{status}"
    end
  end

  test "an error term that could hold the request keeps only its step" do
    request = %{headers: %{"x-plex-token" => [@token]}}

    expect_account(owner())
    expect_machine_id({:ok, "machine-1"})
    expect_share_ids({:error, {:closed, request}})

    assert SignInProbe.health() == {:error, {:server_shares, :error}}
  end

  describe "reason/1" do
    test "keeps a closed set, and gives the same answer twice" do
      for {input, expected} <- [
            {:timeout, :timeout},
            {:not_configured, :not_configured},
            {:token_rejected, :token_rejected},
            {{:owner_account, {:plex_tv_status, 401}}, :token_rejected},
            {{:server_shares, {:plex_tv_status, 403}}, :token_rejected},
            {{:server_machine_id, {:plex_tv_status, 403}},
             {:server_machine_id, {:plex_tv_status, 403}}},
            {{:owner_account, {:plex_tv_status, 502}}, {:owner_account, {:plex_tv_status, 502}}},
            {{:owner_account, :unexpected_response}, {:owner_account, :unexpected_response}},
            {{:server_shares, %Req.TransportError{reason: :timeout}}, {:server_shares, :timeout}},
            {{:server_shares, %{token: @token}}, {:server_shares, :error}},
            {{:owner_account, "x-plex-token: #{@token}"}, {:owner_account, :error}},
            # A step the probe no longer has, or the gate's refusal, names no step of its own.
            {{:server_ids, :unexpected_response}, :error},
            {{:server_access, {:forbidden, 3}}, :error},
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
