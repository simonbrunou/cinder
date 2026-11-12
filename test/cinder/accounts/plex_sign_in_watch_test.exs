defmodule Cinder.Accounts.PlexSignInWatchTest do
  # async: false — the not-configured ticks blank the global Plex token, and `:start_poller` is
  # global too.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase
  import Mox

  alias Cinder.Accounts.PlexAuthMock
  alias Cinder.Accounts.PlexSignInWatch

  setup :verify_on_exit!

  setup do
    Cinder.TestNotifier.subscribe()
    :ok
  end

  # config/test.exs: the Plex media server's token.
  @token "test-key"
  @probe [timeouts: :probe]

  # A worker of its own, whose first scheduled check never comes during the test. Each tick runs
  # its probe in a task under the worker, so the worker gets the test's expectations.
  defp start_watch do
    name = :"plex_sign_in_watch_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {PlexSignInWatch, name: name, first_interval: :timer.hours(1)},
          id: name
        )
      )

    allow(PlexAuthMock, self(), pid)
    pid
  end

  # Sets up plex.tv's answers for one check, runs it, and returns the health events it sent.
  defp tick(pid, result) do
    answer(result)
    assert :ok = PlexSignInWatch.poll(pid)
    sent()
  end

  defp answer(:pass) do
    owner()
    expect(PlexAuthMock, :resource_ids, fn @token, @probe -> {:ok, ["machine-1"]} end)
  end

  defp answer(:server_not_listed) do
    owner()
    expect(PlexAuthMock, :resource_ids, fn @token, @probe -> {:ok, ["another-server"]} end)
  end

  defp answer(:token_rejected),
    do: expect(PlexAuthMock, :account, fn @token, @probe -> {:error, {:plex_tv_status, 401}} end)

  defp answer(:unexpected_response),
    do: expect(PlexAuthMock, :account, fn @token, @probe -> {:ok, %{id: "1"}} end)

  defp answer(:timeout) do
    expect(PlexAuthMock, :account, fn @token, @probe ->
      {:error, %Req.TransportError{reason: :timeout}}
    end)
  end

  defp answer(:server_error) do
    owner()

    expect(PlexAuthMock, :resource_ids, fn @token, @probe ->
      {:error, {:plex_tv_status, 503}}
    end)
  end

  # The token's own text in an exception, as a raise deep in the HTTP stack could carry it.
  defp answer(:raise),
    do: expect(PlexAuthMock, :account, fn @token, @probe -> raise "x-plex-token: #{@token}" end)

  defp answer(:not_configured), do: put_config(Cinder.Library.MediaServer.Plex, token: "")
  defp answer(:configured), do: put_config(Cinder.Library.MediaServer.Plex, token: @token)

  defp owner do
    expect(PlexAuthMock, :account, fn @token, @probe -> {:ok, %{id: 1}} end)
    expect(PlexAuthMock, :server_machine_id, fn @probe -> {:ok, "machine-1"} end)
  end

  # Every health event already in the mailbox: the worker notifies before `poll/1` replies.
  defp sent(acc \\ []) do
    receive do
      {:notify, {type, :plex_signin} = event} when type == :health_check_recovered ->
        sent([event | acc])

      {:notify, {:health_check_failed, _target, _reason} = event} ->
        sent([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @failed {:health_check_failed, :plex_signin, :server_not_listed}
  @recovered {:health_check_recovered, :plex_signin}
  @timed_out {:health_check_failed, :plex_signin, {:account, :timeout}}

  test "a passing check sends nothing" do
    pid = start_watch()
    assert tick(pid, :pass) == []
    assert tick(pid, :pass) == []
  end

  test "a server plex.tv stops listing is reported at once, once, then its recovery" do
    pid = start_watch()

    assert tick(pid, :pass) == []
    assert tick(pid, :server_not_listed) == [@failed]
    assert tick(pid, :server_not_listed) == []
    assert tick(pid, :server_not_listed) == []
    assert tick(pid, :pass) == [@recovered]
    assert tick(pid, :pass) == []
  end

  test "a rejected token and an unexpected response are reported at once" do
    pid = start_watch()
    assert tick(pid, :token_rejected) == [{:health_check_failed, :plex_signin, :token_rejected}]
    assert tick(pid, :pass) == [@recovered]

    assert tick(pid, :unexpected_response) ==
             [{:health_check_failed, :plex_signin, {:account, :unexpected_response}}]
  end

  test "a timeout is reported only on its second tick in a row, and a third sends nothing" do
    pid = start_watch()

    assert tick(pid, :timeout) == []
    assert tick(pid, :timeout) == [@timed_out]
    assert tick(pid, :timeout) == []
    assert tick(pid, :pass) == [@recovered]
  end

  test "a 5xx needs two ticks in a row too, and reports the second tick's reason" do
    pid = start_watch()

    assert tick(pid, :timeout) == []

    assert tick(pid, :server_error) ==
             [{:health_check_failed, :plex_signin, {:server_ids, {:plex_tv_status, 503}}}]
  end

  test "a lone failure between passes sends nothing, not even a recovery" do
    pid = start_watch()

    assert tick(pid, :timeout) == []
    assert tick(pid, :pass) == []
    assert tick(pid, :timeout) == []
    assert tick(pid, :pass) == []
  end

  test "not configured sends nothing and forgets the failure: the next one counts from zero" do
    pid = start_watch()

    assert tick(pid, :server_not_listed) == [@failed]
    assert tick(pid, :not_configured) == []

    answer(:configured)
    # The reported failure is forgotten, so this pass sends no recovery.
    assert tick(pid, :pass) == []

    assert tick(pid, :timeout) == []
    assert tick(pid, :not_configured) == []
    answer(:configured)
    # The pending timeout is forgotten too: one more counts as the first.
    assert tick(pid, :timeout) == []
    assert tick(pid, :timeout) == [@timed_out]
  end

  test "a fresh worker facing an ongoing failure reports it once" do
    first = start_watch()
    assert tick(first, :server_not_listed) == [@failed]
    # A restart: the state lived in the process that stopped.
    {:registered_name, id} = Process.info(first, :registered_name)
    stop_supervised!(id)

    second = start_watch()
    assert tick(second, :server_not_listed) == [@failed]
    assert tick(second, :server_not_listed) == []
  end

  test "an exception's text never reaches the event, only its module" do
    pid = start_watch()

    assert tick(pid, :raise) == []

    assert [{:health_check_failed, :plex_signin, {:exception, RuntimeError}} = event] =
             tick(pid, :raise)

    refute inspect(event) =~ @token
  end

  test "its own timers run the first check, then the next one an interval later" do
    # The intervals come from config here; the worker is allowed by name before it starts, since
    # its first check may run before `start_supervised!/1` returns.
    put_env(PlexSignInWatch, first_interval: 0, interval: 50)
    name = :"plex_sign_in_watch_#{System.unique_integer([:positive])}"
    allow(PlexAuthMock, self(), fn -> Process.whereis(name) end)
    answer(:server_not_listed)
    answer(:pass)

    start_supervised!(Supervisor.child_spec({PlexSignInWatch, name: name}, id: name))

    assert_receive {:notify, @failed}, 5_000
    assert_receive {:notify, @recovered}, 5_000
    # A third check would find no expectation left.
    stop_supervised!(name)
  end

  test "is supervised only when :start_poller is enabled" do
    put_env(:start_poller, false)
    refute PlexSignInWatch in Cinder.Application.poller_child()

    put_env(:start_poller, true)
    assert PlexSignInWatch in Cinder.Application.poller_child()
  end
end
