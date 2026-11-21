defmodule Cinder.Download.EndpointVetterTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.{EndpointVetter, Torrent}

  @public {:ok, [{93, 184, 216, 34}]}
  # The most unique hosts `EndpointVetter.allowed_hosts/3` looks at per torrent or magnet.
  @host_cap 50
  # Every call whose resolvers all answer at once gets 30 s, headroom for a loaded host: one
  # sighting on #1509 counted 0 resolver calls under the 8 s default. The call returns once every
  # task has answered, so a wide deadline costs a healthy run nothing.
  @deadline_ms 30_000

  defp counting_resolver(counter, reply) do
    fn host ->
      :counters.add(counter, 1, 1)
      reply.(host)
    end
  end

  test "dedupes hosts and caps the unique ones vetted" do
    counter = :counters.new(1, [])
    resolver = counting_resolver(counter, fn _host -> @public end)

    hosts =
      for(n <- 1..500, do: "tracker#{n}.example") ++ List.duplicate("tracker1.example", 100)

    allowed = EndpointVetter.allowed_hosts(hosts, resolver, @deadline_ms)

    assert :counters.get(counter, 1) == @host_cap
    assert MapSet.size(allowed) == @host_cap
    assert MapSet.member?(allowed, "tracker1.example")
    refute MapSet.member?(allowed, "tracker#{@host_cap + 1}.example")
  end

  test "resolves duplicates once" do
    counter = :counters.new(1, [])
    resolver = counting_resolver(counter, fn _host -> @public end)

    assert EndpointVetter.allowed_hosts(
             List.duplicate("tracker.example", 40),
             resolver,
             @deadline_ms
           ) == MapSet.new(["tracker.example"])

    assert :counters.get(counter, 1) == 1
  end

  test "a stalled nameserver is cut off at one overall deadline, keeping what resolved" do
    resolver = fn
      "fast.example" ->
        @public

      _slow ->
        Process.sleep(:infinity)
    end

    hosts = ["fast.example" | for(n <- 1..40, do: "slow#{n}.example")]

    # 10 s, the deadline testing.md gives a call meant to finish, leaves `fast.example` headroom
    # to answer on a loaded host (#1509). The call waits the full 10 s out on every run.
    {micros, allowed} =
      :timer.tc(fn -> EndpointVetter.allowed_hosts(hosts, resolver, 10_000) end)

    assert allowed == MapSet.new(["fast.example"])
    # One deadline for the whole batch: waiting 10 s on each stalled host in turn would take
    # about 40 x 10 s, which ExUnit's default 60 s test timeout fails before this assert runs.
    # A separate 10 s deadline per host, all running at once, passes this test too.
    assert micros < 30_000_000
  end

  test "forbidden and unresolvable hosts are dropped" do
    resolver = fn
      "lan.example" -> {:ok, [{192, 168, 1, 10}]}
      "dead.example" -> {:error, :nxdomain}
      _host -> @public
    end

    assert EndpointVetter.allowed_hosts(
             ["lan.example", "dead.example", "ok.example"],
             resolver,
             @deadline_ms
           ) == MapSet.new(["ok.example"])
  end

  test "a magnet with thousands of tracker hosts costs a bounded number of lookups" do
    counter = :counters.new(1, [])
    resolver = counting_resolver(counter, fn _host -> @public end)

    trackers =
      Enum.map_join(1..3000, "&", fn n ->
        "tr=" <> URI.encode_www_form("udp://t#{n}.example:1337/announce")
      end)

    magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&" <> trackers

    assert {:ok, clean} =
             Torrent.sanitize_magnet(
               magnet,
               &EndpointVetter.allowed_hosts(&1, resolver, @deadline_ms)
             )

    assert :counters.get(counter, 1) == @host_cap

    kept = clean |> URI.parse() |> Map.fetch!(:query) |> URI.query_decoder() |> Enum.to_list()
    assert Enum.count(kept, fn {k, _} -> k == "tr" end) == @host_cap
    assert {"xt", "urn:btih:0123456789abcdef0123456789abcdef01234567"} in kept
  end
end
