defmodule Cinder.Accounts.IpRateLimiterTest do
  # async: false — toggles the global :ip_rate_limiting flag and shares one ETS table.
  use ExUnit.Case, async: false

  alias Cinder.Accounts.IpRateLimiter

  @ip "203.0.113.50"

  setup do
    previous = Application.get_env(:cinder, :ip_rate_limiting)
    Application.put_env(:cinder, :ip_rate_limiting, true)
    IpRateLimiter.reset()

    on_exit(fn ->
      IpRateLimiter.reset()

      if is_nil(previous),
        do: Application.delete_env(:cinder, :ip_rate_limiting),
        else: Application.put_env(:cinder, :ip_rate_limiting, previous)
    end)

    :ok
  end

  test "not blocked under the limit, blocked at the limit" do
    refute IpRateLimiter.blocked?(:login, @ip)

    # @limit is 10 — the 10th attempt trips the bucket.
    for _ <- 1..10, do: IpRateLimiter.register_attempt(:login, @ip)

    assert IpRateLimiter.blocked?(:login, @ip)
  end

  test "check_and_register is atomic under a concurrent burst (no bypass)" do
    parent = self()

    runner =
      Task.async(fn ->
        1..100
        |> Task.async_stream(
          fn _ ->
            send(parent, {:ready, self()})
            receive do: (:go -> IpRateLimiter.check_and_register(:login, @ip))
          end,
          max_concurrency: 100,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, verdict} -> verdict end)
      end)

    # Barrier: release all 100 at once so they race the check-then-increment window.
    tasks = for _ <- 1..100, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(tasks, &send(&1, :go))
    results = Task.await(runner)

    # Exactly @limit succeed; the rest are blocked. A non-atomic gate would let many more through.
    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &(&1 == :blocked)) == 90
  end

  test "buckets are independent for the same IP" do
    for _ <- 1..10, do: IpRateLimiter.register_attempt(:login, @ip)

    assert IpRateLimiter.blocked?(:login, @ip)
    refute IpRateLimiter.blocked?(:registration, @ip)
  end

  test "different IPs have independent budgets" do
    for _ <- 1..10, do: IpRateLimiter.register_attempt(:login, @ip)

    assert IpRateLimiter.blocked?(:login, @ip)
    refute IpRateLimiter.blocked?(:login, "198.51.100.1")
  end

  test "clear/2 releases the bucket" do
    for _ <- 1..10, do: IpRateLimiter.register_attempt(:login, @ip)
    assert IpRateLimiter.blocked?(:login, @ip)

    IpRateLimiter.clear(:login, @ip)
    refute IpRateLimiter.blocked?(:login, @ip)
  end

  test "disabled flag makes it a no-op that never blocks" do
    Application.put_env(:cinder, :ip_rate_limiting, false)

    for _ <- 1..50, do: IpRateLimiter.register_attempt(:login, @ip)

    refute IpRateLimiter.blocked?(:login, @ip)
  end
end
