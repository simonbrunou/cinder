defmodule Cinder.Acquisition.Indexer.Cardigann.JarTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Jar

  @site URI.parse("https://site.test/browse")
  @hosts MapSet.new(["site.test"])

  defp response(set_cookies) do
    Enum.reduce(set_cookies, %Req.Response{status: 200}, fn cookie, response ->
      Req.Response.put_header(response, "set-cookie", cookie)
    end)
  end

  test "a credential host's Set-Cookie goes back to its own origin only" do
    jar = Jar.keep(Jar.new(), @site, response(["sid=1; path=/"]), @hosts)

    assert Jar.header(jar, URI.parse("https://site.test/other"), @hosts) == [{"cookie", "sid=1"}]
    assert Jar.header(jar, URI.parse("http://site.test/"), @hosts) == []
    assert Jar.header(jar, URI.parse("https://site.test:8443/"), @hosts) == []
  end

  test "another host's Set-Cookie is dropped" do
    jar = Jar.keep(Jar.new(), URI.parse("https://other.test/"), response(["evil=1"]), @hosts)
    assert Jar.empty?(jar)
  end

  test "a stored cookie of a host that is no longer a credential host is not sent" do
    jar = Jar.put_string(Jar.new(), @site, "sid=1")
    assert Jar.header(jar, @site, MapSet.new(["elsewhere.test"])) == []
  end

  test "a pair with a control character, a comma or 4 KiB is dropped; a blank name too" do
    long = String.duplicate("v", 4_096)

    jar =
      Jar.keep(
        Jar.new(),
        @site,
        response(["a=1\u0001", "b=1,2", "c=" <> long, "=x", "ok=1"]),
        @hosts
      )

    assert Jar.to_list(jar) == [["https", "site.test", 443, "ok", "1"]]
  end

  test "an origin keeps at most 32 names: a new one past them is dropped, a known one replaced" do
    full = Enum.reduce(1..32, Jar.new(), &Jar.put_string(&2, @site, "n#{&1}=1"))
    jar = full |> Jar.put_string(@site, "n33=1") |> Jar.put_string(@site, "n1=2")

    names = for [_scheme, _host, _port, name, value] <- Jar.to_list(jar), do: {name, value}
    assert length(names) == 32
    refute List.keymember?(names, "n33", 0)
    assert {"n1", "2"} in names
  end

  test "a fixed pair goes to every credential host, on any scheme and port, and a pair its own origin set wins" do
    hosts = MapSet.new(["site.test", "mirror.test"])
    jar = Jar.put_fixed(Jar.new(), "sid=fixed; uid=7")

    for uri <- ["https://site.test/", "http://site.test/", "https://mirror.test:8443/x"] do
      assert Jar.header(jar, URI.parse(uri), hosts) == [{"cookie", "sid=fixed; uid=7"}]
    end

    assert Jar.header(jar, URI.parse("https://other.test/"), hosts) == []

    jar = Jar.keep(jar, @site, response(["sid=new"]), hosts)
    assert Jar.header(jar, @site, hosts) == [{"cookie", "sid=new; uid=7"}]

    assert Jar.header(jar, URI.parse("https://mirror.test/"), hosts) == [
             {"cookie", "sid=fixed; uid=7"}
           ]
  end

  test "the stored list reads back, and anything else reads :error" do
    jar = Jar.put_string(Jar.put_fixed(Jar.new(), "f=0"), @site, "a=1; b=2")

    assert Jar.to_list(jar) == [
             ["f", "0"],
             ["https", "site.test", 443, "a", "1"],
             ["https", "site.test", 443, "b", "2"]
           ]

    assert {:ok, ^jar} = jar |> Jar.to_list() |> Jar.from_list()
    assert Jar.from_list([["https", "site.test", "443", "a", "1"]]) == :error
    assert Jar.from_list(%{}) == :error
  end

  test "inspect shows no cookie" do
    jar = Jar.put_string(Jar.new(), @site, "sid=s3cr3t")
    refute inspect(jar) =~ "s3cr3t"
  end
end
