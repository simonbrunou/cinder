defmodule Cinder.Accounts.PasskeyChallengesTest do
  # async: false: the store is one named table shared by the whole run, and these tests fill it,
  # shrink its TTL and take it away.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase, only: [put_env: 2]

  alias Cinder.Accounts.PasskeyChallenges

  @table :cinder_passkey_challenges

  setup do
    :ets.delete_all_objects(@table)
    on_exit(fn -> :ets.delete_all_objects(@table) end)
  end

  defp challenge,
    do:
      Wax.new_authentication_challenge(origin: "https://cinder.example", rp_id: "cinder.example")

  test "a handle answers once: the second take finds nothing" do
    c = challenge()
    {:ok, handle} = PasskeyChallenges.put(c, :sign_in)

    assert {:ok, ^c} = PasskeyChallenges.take(handle, :sign_in)
    assert {:error, :unknown} = PasskeyChallenges.take(handle, :sign_in)
  end

  test "two handles never collide and each returns its own challenge" do
    c1 = challenge()
    c2 = challenge()
    {:ok, h1} = PasskeyChallenges.put(c1, :sign_in)
    {:ok, h2} = PasskeyChallenges.put(c2, :sign_in)

    assert h1 != h2
    assert {:ok, ^c2} = PasskeyChallenges.take(h2, :sign_in)
    assert {:ok, ^c1} = PasskeyChallenges.take(h1, :sign_in)
  end

  test "an entry past its TTL is refused as expired, and the take still consumes it" do
    put_env(:passkey_challenge_ttl_ms, 50)
    {:ok, handle} = PasskeyChallenges.put(challenge(), :sign_in)
    Process.sleep(60)

    assert {:error, :expired} = PasskeyChallenges.take(handle, :sign_in)
    assert {:error, :unknown} = PasskeyChallenges.take(handle, :sign_in)
  end

  test "an entry lives 3 minutes by default" do
    before = System.monotonic_time(:millisecond)
    {:ok, handle} = PasskeyChallenges.put(challenge(), :sign_in)
    [{^handle, :sign_in, _challenge, expires_at}] = :ets.lookup(@table, handle)

    assert PasskeyChallenges.ttl_ms() == 180_000
    assert (expires_at - before) in 180_000..181_000
  end

  test "an entry inside its TTL is fresh" do
    put_env(:passkey_challenge_ttl_ms, 10_000)
    c = challenge()
    {:ok, handle} = PasskeyChallenges.put(c, :sign_in)

    assert {:ok, ^c} = PasskeyChallenges.take(handle, :sign_in)
  end

  test "a take for another purpose is refused and consumes the entry" do
    {:ok, handle} = PasskeyChallenges.put(challenge(), {:register, 1})

    assert {:error, :wrong_purpose} = PasskeyChallenges.take(handle, {:register, 2})
    assert {:error, :unknown} = PasskeyChallenges.take(handle, {:register, 1})

    {:ok, handle} = PasskeyChallenges.put(challenge(), :sign_in)
    assert {:error, :wrong_purpose} = PasskeyChallenges.take(handle, {:register, 1})
  end

  test "a handle that is not a string is unknown" do
    assert {:error, :unknown} = PasskeyChallenges.take(nil, :sign_in)
    assert {:error, :unknown} = PasskeyChallenges.take(%{}, :sign_in)
  end

  test "the defaults: 10,000 sign-in entries, 1,000 registration entries" do
    assert PasskeyChallenges.max_entries(:sign_in) == 10_000
    assert PasskeyChallenges.max_entries(:register) == 1_000
  end

  test "the store holds at most max_entries live entries, and makes room by dropping expired ones" do
    put_env(:passkey_challenge_max_entries, %{sign_in: 40})
    max = PasskeyChallenges.max_entries(:sign_in)
    put_env(:passkey_challenge_ttl_ms, 60_000)

    for _ <- 1..(max - 1), do: {:ok, _} = PasskeyChallenges.put(challenge(), :sign_in)

    # The last free slot goes to an entry that expires at once.
    put_env(:passkey_challenge_ttl_ms, 0)
    assert {:ok, _} = PasskeyChallenges.put(challenge(), :sign_in)
    assert :ets.info(@table, :size) == max

    # Full: the next put sweeps the expired entry and takes its place.
    put_env(:passkey_challenge_ttl_ms, 60_000)
    assert {:ok, last} = PasskeyChallenges.put(challenge(), :sign_in)
    assert :ets.info(@table, :size) == max

    # Full of live entries: refused, nothing inserted.
    assert {:error, :full} = PasskeyChallenges.put(challenge(), :sign_in)
    assert :ets.info(@table, :size) == max
    assert {:ok, _} = PasskeyChallenges.take(last, :sign_in)
  end

  test "a full sign-in pool leaves registration room, and registration has its own cap" do
    put_env(:passkey_challenge_max_entries, %{sign_in: 30, register: 3})
    put_env(:passkey_challenge_ttl_ms, 60_000)

    # Registration entries take no sign-in room: all 30 sign-in puts still fit after them.
    for user_id <- 1..3,
        do: assert({:ok, _} = PasskeyChallenges.put(challenge(), {:register, user_id}))

    for _ <- 1..30, do: assert({:ok, _} = PasskeyChallenges.put(challenge(), {:sign_in, nil}))
    assert {:error, :full} = PasskeyChallenges.put(challenge(), {:sign_in, nil})

    # A full sign-in pool takes no registration room, and registration stops at its own cap.
    :ets.match_delete(@table, {:_, {:register, 3}, :_, :_})
    assert {:ok, _} = PasskeyChallenges.put(challenge(), {:register, 3})
    assert {:error, :full} = PasskeyChallenges.put(challenge(), {:register, 4})
    assert :ets.info(@table, :size) == 33
  end

  test "puts racing for the last free slot never pass max_entries" do
    put_env(:passkey_challenge_max_entries, %{sign_in: 200})
    max = PasskeyChallenges.max_entries(:sign_in)
    put_env(:passkey_challenge_ttl_ms, 60_000)

    # The race does not lose on every round, so run many.
    for _ <- 1..80 do
      :ets.delete_all_objects(@table)
      for _ <- 1..(max - 1), do: {:ok, _} = PasskeyChallenges.put(challenge(), :sign_in)
      parent = self()
      gate = make_ref()

      racers =
        for _ <- 1..24 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              ^gate -> PasskeyChallenges.put(challenge(), :sign_in)
            end
          end)
        end

      for racer <- racers, do: assert_receive({:ready, pid} when pid == racer.pid, 1_000)
      for racer <- racers, do: send(racer.pid, gate)
      results = Task.await_many(racers)

      assert :ets.info(@table, :size) == max
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    end
  end

  test "the periodic sweep drops expired entries and keeps live ones" do
    put_env(:passkey_challenge_ttl_ms, 0)
    {:ok, expired} = PasskeyChallenges.put(challenge(), :sign_in)
    put_env(:passkey_challenge_ttl_ms, 60_000)
    {:ok, live} = PasskeyChallenges.put(challenge(), :sign_in)

    send(PasskeyChallenges, :sweep)
    :sys.get_state(PasskeyChallenges)

    assert :ets.lookup(@table, expired) == []
    assert [_] = :ets.lookup(@table, live)
  end

  test "with its table gone the store fails closed" do
    pid = Process.whereis(PasskeyChallenges)
    {:ok, handle} = PasskeyChallenges.put(challenge(), :sign_in)

    # The table belongs to the GenServer; stop it and refuse while its supervisor restarts it.
    :ok = Supervisor.terminate_child(Cinder.Supervisor, PasskeyChallenges)

    try do
      assert {:error, :unavailable} = PasskeyChallenges.put(challenge(), :sign_in)
      assert {:error, :unavailable} = PasskeyChallenges.take(handle, :sign_in)
    after
      {:ok, _} = Supervisor.restart_child(Cinder.Supervisor, PasskeyChallenges)
    end

    refute Process.whereis(PasskeyChallenges) == pid
  end
end
