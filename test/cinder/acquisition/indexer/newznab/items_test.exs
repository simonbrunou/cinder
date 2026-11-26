defmodule Cinder.Acquisition.Indexer.Newznab.ItemsTest do
  # The rows a Newznab or Torznab answer's items give (#1653, #1618 points 6 and 7, #1621 point 3
  # and its amendment point 4). The element names follow Prowlarr's `NewznabRssParser`,
  # `TorznabRssParser` and `RssParser` (`b0b5774`): `enclosure` with `url`, `type` and `length`,
  # `newznab:attr` or `torznab:attr` with `name` and `value`, `title`, `pubDate`, and the `size`
  # element Prowlarr's own feed writes (`NewznabResults.cs`).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Newznab.{Items, XML}
  alias Cinder.Indexers.ConfiguredIndexer

  @torrent_type "application/x-bittorrent"
  @nzb_type "application/x-nzb"

  defp indexer(type, base_url), do: %ConfiguredIndexer{type: type, base_url: base_url}

  defp items(xml) do
    {:ok, {"rss", _, _} = rss} =
      XML.parse(
        ~s(<rss xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/" ) <>
          ~s(xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel>#{xml}</channel></rss>)
      )

    for {"item", _, _} = item <- XML.elements(XML.child(rss, "channel")), do: item
  end

  defp rows(type, xml, base_url \\ "https://indexer.example/prowlarr/1"),
    do: Items.rows(items(xml), indexer(type, base_url))

  defp enclosure(url, type), do: ~s(<enclosure url="#{url}" type="#{type}" length="7"/>)

  defp attr(prefix \\ "newznab", name, value),
    do: ~s(<#{prefix}:attr name="#{name}" value="#{value}"/>)

  defp item(title, body), do: "<item><title>#{title}</title>#{body}</item>"

  defp nzb_item(title, url \\ "https://indexer.example/get/1.nzb"),
    do: item(title, enclosure(url, @nzb_type))

  describe "rows/2 required fields" do
    test "a Newznab item gives a Usenet row with its NZB link and every field it states" do
      xml =
        item(
          "Show.S01E01.1080p.WEB-DL-GRP",
          enclosure("https://indexer.example/get/1.nzb", @nzb_type) <>
            "<pubDate>Wed, 25 Nov 2026 10:30:00 +0100</pubDate>" <>
            attr("size", "2000000000") <>
            attr("category", "5000") <> attr("category", "5040") <> attr("tvdbid", "81189")
        )

      assert rows(:newznab, xml) == [
               %{
                 title: "Show.S01E01.1080p.WEB-DL-GRP",
                 download_url: "https://indexer.example/get/1.nzb",
                 download_url_origin: "https://indexer.example/prowlarr/1",
                 protocol: :usenet,
                 size: 2_000_000_000,
                 category_ids: [5000, 5040],
                 published_at: ~U[2026-11-25 09:30:00Z],
                 tvdb_id: 81_189
               }
             ]
    end

    test "a Torznab item gives a torrent row" do
      xml =
        item("Movie.2020.1080p", enclosure("https://indexer.example/t/1.torrent", @torrent_type))

      assert [%{protocol: :torrent, download_url: "https://indexer.example/t/1.torrent"}] =
               rows(:torznab, xml)
    end

    test "a blank or missing title drops the row" do
      for title <- ["", "   ", "\n\t"] do
        assert {title, rows(:newznab, nzb_item(title))} == {title, []}
      end

      assert rows(
               :newznab,
               "<item>#{enclosure("https://indexer.example/x.nzb", @nzb_type)}</item>"
             ) ==
               []
    end

    test "a title of 1,024 bytes is kept and one of 1,025 bytes drops the row" do
      # Two-byte characters, so a cut by characters rather than bytes would keep the long one.
      kept = String.duplicate("é", 512)
      dropped = "a" <> kept

      assert byte_size(kept) == 1024 and byte_size(dropped) == 1025
      assert [%{title: ^kept}] = rows(:newznab, nzb_item(kept))
      assert rows(:newznab, nzb_item(dropped)) == []
    end

    test "a title's text is joined across entities and CDATA, and trimmed" do
      xml = nzb_item("\n  Law &amp; Order <![CDATA[S01]]> &#233;  ")
      assert [%{title: "Law & Order S01 é"}] = rows(:newznab, xml)
    end

    test "an item with no link drops the row" do
      for body <- [
            "",
            ~s(<enclosure type="#{@nzb_type}"/>),
            enclosure("", @nzb_type),
            enclosure("ftp://indexer.example/1.nzb", @nzb_type),
            enclosure("/relative/1.nzb", @nzb_type),
            ~s(<link>https://indexer.example/1.nzb</link>)
          ] do
        assert {body, rows(:newznab, item("Name", body))} == {body, []}
      end
    end
  end

  describe "rows/2 link order" do
    test "a Torznab item takes its torrent file over its magnet" do
      xml =
        item(
          "Name",
          attr("torznab", "magneturl", "magnet:?xt=urn:btih:abc") <>
            enclosure("https://indexer.example/t/1.torrent", @torrent_type)
        )

      assert [%{download_url: "https://indexer.example/t/1.torrent"}] = rows(:torznab, xml)
    end

    test "a Torznab item with only a magnet takes the magnet, from magneturl or an enclosure" do
      magnet = "magnet:?xt=urn:btih:abc&amp;dn=Name"

      assert [%{download_url: "magnet:?xt=urn:btih:abc&dn=Name", download_url_origin: nil}] =
               rows(:torznab, item("Name", attr("torznab", "magneturl", magnet)))

      assert [%{download_url: "magnet:?xt=urn:btih:abc&dn=Name", download_url_origin: nil}] =
               rows(:torznab, item("Name", enclosure(magnet, @torrent_type)))
    end

    test "a torrent file beats the magnet whatever order the elements come in" do
      xml =
        item(
          "Name",
          enclosure("magnet:?xt=urn:btih:abc", @torrent_type) <>
            enclosure("https://indexer.example/t/1.torrent", @torrent_type)
        )

      assert [%{download_url: "https://indexer.example/t/1.torrent"}] = rows(:torznab, xml)
    end

    test "an enclosure with no type is the file of the indexer's own protocol" do
      untyped = ~s(<enclosure url="https://indexer.example/f/1"/>)

      assert [%{download_url: "https://indexer.example/f/1", protocol: :torrent}] =
               rows(:torznab, item("Name", untyped))

      assert [%{download_url: "https://indexer.example/f/1", protocol: :usenet}] =
               rows(:newznab, item("Name", untyped))

      # A typed torrent file still beats an untyped enclosure on a torrent indexer.
      xml =
        item("Name", untyped <> enclosure("https://indexer.example/t/1.torrent", @torrent_type))

      assert [%{download_url: "https://indexer.example/t/1.torrent"}] = rows(:torznab, xml)
    end

    test "a type with parameters or in another case still names the file" do
      xml =
        item("Name", enclosure("https://indexer.example/1.nzb", "Application/X-NZB; charset=x"))

      assert [%{download_url: "https://indexer.example/1.nzb"}] = rows(:newznab, xml)
    end

    test "a link the indexer's protocol cannot carry is skipped, so it never hides the NZB link" do
      # #1621 point 3: a magnet is refused for Usenet. A Usenet row reads only the NZB link.
      xml =
        item(
          "Name",
          enclosure("https://indexer.example/t/1.torrent", @torrent_type) <>
            attr("magneturl", "magnet:?xt=urn:btih:abc") <>
            enclosure("https://indexer.example/get/1.nzb", @nzb_type)
        )

      assert [%{download_url: "https://indexer.example/get/1.nzb", protocol: :usenet}] =
               rows(:newznab, xml)

      assert rows(:newznab, item("Name", attr("magneturl", "magnet:?xt=urn:btih:abc"))) == []

      assert rows(:torznab, nzb_item("Name")) == []
    end

    test "an enclosure that is not http(s) or a magnet never hides a usable one" do
      xml =
        item(
          "Name",
          enclosure("not a url", @torrent_type) <>
            ~s(<enclosure url="https://indexer.example/cover.jpg" type="image/jpeg"/>) <>
            enclosure("https://indexer.example/t/1.torrent", @torrent_type)
        )

      assert [%{download_url: "https://indexer.example/t/1.torrent"}] = rows(:torznab, xml)
    end

    test "a link needs an http(s) URL with a host, an IPv6 one included" do
      for url <- [
            "http://@",
            "http://%zz",
            "https://?",
            "http:/indexer.example/1",
            "https://a b/",
            "https://indexer.example/a b.nzb",
            "ftp://indexer.example/1.nzb",
            "http://indexer!example/1.nzb",
            "http://[a:b/x",
            "http://a:b:c/x",
            "http://[indexer.example]/x",
            "http://indexer.example:abc/x",
            "http://[zz:zz]/x",
            "http://~/x",
            "http://.../x"
          ] do
        assert {url, rows(:newznab, nzb_item("N", url))} == {url, []}
      end

      for url <- [
            "HTTPS://Indexer.example:8443/1.nzb?x=1",
            "http://[::1]/1.nzb",
            "http://prowlarr_app:9696/1/download?apikey=k",
            "https://user:pass@indexer.example/1.nzb",
            "https://indexer.example/get?file=Amélie.nzb",
            "https://indexer.example/get?file=A|B.nzb",
            "https://indexer.example/get?f=[x]"
          ] do
        assert {^url, [%{download_url: ^url}]} = {url, rows(:newznab, nzb_item("N", url))}
      end
    end
  end

  describe "rows/2 optional fields" do
    test "missing or invalid size, categories, publication time and TVDB id read nil" do
      for body <- [
            "",
            attr("size", "-1") <>
              attr("category", "TV") <> "<pubDate>yesterday</pubDate>" <> attr("tvdbid", "x"),
            attr("size", "") <>
              attr("category", "-5") <> "<pubDate></pubDate>" <> attr("tvdbid", "0"),
            attr("size", "1.5e9") <> attr("tvdbid", "-3"),
            ~s(<newznab:attr name="size"/><newznab:attr value="9"/>)
          ] do
        xml = item("Name", ~s(<enclosure url="https://indexer.example/1.nzb"/>) <> body)

        assert {^body, [row]} = {body, rows(:newznab, xml)}

        assert {body, Map.take(row, [:size, :category_ids, :published_at, :tvdb_id])} ==
                 {body, %{size: nil, category_ids: nil, published_at: nil, tvdb_id: nil}}
      end
    end

    test "a number of more than 18 digits reads as none, and one of 18 is read" do
      link = ~s(<enclosure url="https://indexer.example/1.nzb" type="#{@nzb_type}"/>)
      eighteen = String.duplicate("9", 18)

      for long <- [String.duplicate("9", 19), String.duplicate("9", 2_000_000)] do
        xml =
          item(
            "N",
            link <>
              attr("size", long) <> attr("category", long) <> attr("tvdbid", long)
          )

        assert [%{size: nil, category_ids: nil, tvdb_id: nil}] = rows(:newznab, xml)
      end

      xml =
        item(
          "N",
          link <> attr("size", eighteen) <> attr("category", eighteen) <> attr("tvdbid", eighteen)
        )

      value = String.to_integer(eighteen)
      assert [%{size: ^value, category_ids: [^value], tvdb_id: ^value}] = rows(:newznab, xml)
    end

    test "size falls back to the size element, then to the link's enclosure length" do
      link = ~s(<enclosure url="https://indexer.example/1.nzb" type="#{@nzb_type}" length="300"/>)

      assert [%{size: 100}] =
               rows(:newznab, item("N", link <> attr("size", "100") <> "<size>200</size>"))

      assert [%{size: 200}] = rows(:newznab, item("N", link <> "<size>200</size>"))
      assert [%{size: 300}] = rows(:newznab, item("N", link))

      other = ~s(<enclosure url="https://indexer.example/c.jpg" type="image/jpeg" length="900"/>)
      assert [%{size: 300}] = rows(:newznab, item("N", other <> link))
    end

    test "attribute names read in any case, from either prefix, and categories keep their order" do
      xml =
        item(
          "N",
          ~s(<enclosure url="https://indexer.example/1.nzb"/>) <>
            attr("torznab", "Category", "5040") <>
            attr("newznab", "CATEGORY", "5000") <> attr("category", "5040") <> attr("TVDBID", "7")
        )

      assert [%{category_ids: [5040, 5000], tvdb_id: 7}] = rows(:newznab, xml)
    end

    test "a publication time reads RFC 822 dates with a zone name or a numeric offset" do
      for {text, expected} <- [
            {"Wed, 25 Nov 2026 10:30:00 GMT", ~U[2026-11-25 10:30:00Z]},
            {"25 Nov 2026 10:30:00 -0500", ~U[2026-11-25 15:30:00Z]},
            {"Wed, 5 Nov 2026 10:30 +0000", ~U[2026-11-05 10:30:00Z]},
            {"Wed, 25 Nov 2026 10:30:00 UTC", ~U[2026-11-25 10:30:00Z]},
            {"Wed, 31 Feb 2026 10:30:00 GMT", nil},
            {"Wed, 25 Nov 2026 25:30:00 GMT", nil},
            {"Wed, 25 Nov 2026 10:30:00 EST", nil},
            {"2026-11-25T10:30:00Z", nil}
          ] do
        xml =
          item(
            "N",
            ~s(<enclosure url="https://indexer.example/1.nzb"/><pubDate>#{text}</pubDate>)
          )

        assert {^text, [%{published_at: ^expected}]} = {text, rows(:newznab, xml)}
      end
    end

    test "no row carries seeders, an info hash, grabs or freeleech" do
      xml =
        item(
          "N",
          enclosure("https://indexer.example/t/1.torrent", @torrent_type) <>
            attr("torznab", "seeders", "9") <>
            attr("torznab", "infohash", "abc") <>
            attr("torznab", "grabs", "3") <> attr("torznab", "downloadvolumefactor", "0")
        )

      assert [row] = rows(:torznab, xml)

      assert Map.keys(row) |> Enum.sort() ==
               ~w(category_ids download_url download_url_origin protocol published_at size title tvdb_id)a
    end
  end

  describe "rows/2 limits" do
    test "1,001 items give the first 1,000 rows" do
      xml = Enum.map_join(1..1001, &nzb_item("N#{&1}", "https://indexer.example/get/#{&1}.nzb"))
      rows = rows(:newznab, xml)

      assert length(rows) == 1000
      assert List.last(rows).title == "N1000"
    end

    test "a repeated link keeps its first copy, and the cap counts kept rows only" do
      # Item 2 repeats item 1's link and item 3 has no link: 1,002 items give 1,000 rows, the
      # last one item 1,002, so the dedupe and the drop run before the cap.
      xml =
        nzb_item("N1", "https://indexer.example/get/1.nzb") <>
          nzb_item("N2", "https://indexer.example/get/1.nzb") <>
          item("N3", "") <>
          Enum.map_join(4..1002, &nzb_item("N#{&1}", "https://indexer.example/get/#{&1}.nzb"))

      rows = rows(:newznab, xml)

      assert length(rows) == 1000
      assert hd(rows).title == "N1"
      refute Enum.any?(rows, &(&1.title in ["N2", "N3"]))
      assert List.last(rows).title == "N1002"
    end
  end

  describe "rows/2 origin" do
    test "a link on the base URL's origin gets the base URL's source origin, userinfo dropped" do
      xml = nzb_item("N", "https://indexer.example:443/other/path/1.nzb")

      assert [%{download_url_origin: "https://indexer.example/prowlarr/1"}] = rows(:newznab, xml)

      assert [%{download_url_origin: "https://indexer.example/api"}] =
               rows(:newznab, nzb_item("N"), "https://user:pass@indexer.example/api#frag")
    end

    test "a link on another host, port or scheme, and every magnet, carries none" do
      for url <- [
            "https://other.example/1.nzb",
            "https://indexer.example.evil.example/1.nzb",
            "https://indexer.example:8443/1.nzb",
            "http://indexer.example/1.nzb"
          ] do
        assert {^url, [%{download_url_origin: nil}]} = {url, rows(:newznab, nzb_item("N", url))}
      end

      magnet = item("N", attr("torznab", "magneturl", "magnet:?xt=urn:btih:abc"))
      assert [%{download_url_origin: nil}] = rows(:torznab, magnet, "magnet:?xt=urn:btih:abc")
    end
  end
end
