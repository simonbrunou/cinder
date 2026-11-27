defmodule Cinder.Acquisition.Indexer.Cardigann.FetchTest do
  # The pinned certificates `Fetch` hands `Cinder.HTTPPolicy.PinnedAdapter` (#1678).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Fetch

  @sha :crypto.hash(:sha, "a certificate")
  @hex Base.encode16(@sha)

  describe "certificate_pins/2" do
    test "reads each entry's hex digits in either case, for the base URL host" do
      mixed = String.downcase(binary_part(@hex, 0, 20)) <> binary_part(@hex, 20, 20)

      for hex <- [@hex, String.downcase(@hex), mixed] do
        assert Fetch.certificate_pins(%{certificates: [hex]}, "https://Site.test/") ==
                 {"Site.test", [@sha]}
      end
    end

    test "is nil with no certificates or a base URL with no host" do
      assert Fetch.certificate_pins(%{certificates: []}, "https://site.test/") == nil
      assert Fetch.certificate_pins(%{certificates: nil}, "https://site.test/") == nil
      assert Fetch.certificate_pins(%{}, "https://site.test/") == nil
      assert Fetch.certificate_pins(%{certificates: [@hex]}, nil) == nil
      assert Fetch.certificate_pins(%{certificates: [@hex]}, "site.test") == nil
    end
  end

  describe "pin_options/2" do
    defp target(url), do: target(url, hostname: URI.parse(url).host)

    defp target(url, connect_options),
      do: %{uri: URI.parse(url), url: URI.parse(url), connect_options: connect_options}

    defp pins(host), do: %{certificate_pins: {host, [@sha]}}

    test "carries the pins to an HTTPS target on the base URL host, its case and dot aside" do
      for url <- ["https://site.test/search", "https://SITE.test./search"] do
        assert Fetch.pin_options(target(url), pins("Site.test")) ==
                 [certificate_pins: {"site.test", [@sha]}]
      end
    end

    test "carries none to another host, a plain HTTP target, an unpinned target or no pins" do
      assert Fetch.pin_options(target("https://cdn.site.test/x"), pins("site.test")) == []
      assert Fetch.pin_options(target("http://site.test/x"), pins("site.test")) == []
      assert Fetch.pin_options(target("https://site.test/x", []), pins("site.test")) == []
      assert Fetch.pin_options(target("https://site.test/x"), %{certificate_pins: nil}) == []
      assert Fetch.pin_options(target("https://site.test/x"), %{}) == []

      assert Fetch.pin_options(target("https://site.test/x"), %{
               certificate_pins: {"site.test", []}
             }) == []
    end
  end
end
