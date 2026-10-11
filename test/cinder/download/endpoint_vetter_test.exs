defmodule Cinder.Download.EndpointVetterTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.{EndpointVetter, Torrent}

  @public {:ok, [{93, 184, 216, 34}]}

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

    allowed = EndpointVetter.allowed_hosts(hosts, resolver)

    assert :counters.get(counter, 1) == EndpointVetter.max_hosts()
    assert MapSet.size(allowed) == EndpointVetter.max_hosts()
    assert MapSet.member?(allowed, "tracker1.example")
    refute MapSet.member?(allowed, "tracker#{EndpointVetter.max_hosts() + 1}.example")
  end

  test "resolves duplicates once" do
    counter = :counters.new(1, [])
    resolver = counting_resolver(counter, fn _host -> @public end)

    assert EndpointVetter.allowed_hosts(List.duplicate("tracker.example", 40), resolver) ==
             MapSet.new(["tracker.example"])

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

    {micros, allowed} =
      :timer.tc(fn -> EndpointVetter.allowed_hosts(hosts, resolver, 300) end)

    assert allowed == MapSet.new(["fast.example"])
    # One deadline for the whole batch, not one per host.
    assert micros < 2_000_000
  end

  test "forbidden and unresolvable hosts are dropped" do
    resolver = fn
      "lan.example" -> {:ok, [{192, 168, 1, 10}]}
      "dead.example" -> {:error, :nxdomain}
      _host -> @public
    end

    assert EndpointVetter.allowed_hosts(["lan.example", "dead.example", "ok.example"], resolver) ==
             MapSet.new(["ok.example"])
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
             Torrent.sanitize_magnet(magnet, &EndpointVetter.allowed_hosts(&1, resolver))

    assert :counters.get(counter, 1) == EndpointVetter.max_hosts()

    kept = clean |> URI.parse() |> Map.fetch!(:query) |> URI.query_decoder() |> Enum.to_list()
    assert Enum.count(kept, fn {k, _} -> k == "tr" end) == EndpointVetter.max_hosts()
    assert {"xt", "urn:btih:0123456789abcdef0123456789abcdef01234567"} in kept
  end
end
