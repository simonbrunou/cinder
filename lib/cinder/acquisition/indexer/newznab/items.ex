defmodule Cinder.Acquisition.Indexer.Newznab.Items do
  @moduledoc """
  The rows of one Newznab or Torznab search answer (#1653, #1618 points 6 and 7): `rows/2` turns
  the `item` elements `Cinder.Acquisition.Indexer.NewznabAnswer.classify/4` answers into release
  maps for one configured indexer. The element names follow Prowlarr's `RssParser`,
  `NewznabRssParser` and `TorznabRssParser` (Prowlarr `b0b5774`).

  ## Required, or the item gives no row

  - `title`: the element's text, every text and CDATA child joined, trimmed, not blank and at
    most 1,024 bytes.
  - `download_url`, from the first of these the indexer's protocol can carry: the torrent file,
    else the magnet, else the NZB link (#1621 amendment point 4). A Torznab indexer carries the
    torrent file and the magnet, a Newznab indexer the NZB link only, since a magnet or a torrent
    file is refused for Usenet (#1621 point 3) and Prowlarr's Newznab parser reads only NZB
    enclosures.
    - The torrent file: the first `enclosure` whose `type` is `application/x-bittorrent` and whose
      `url` is an http(s) URL, else, on a Torznab indexer, the first such `enclosure` with no
      `type`. An http(s) URL starts with `http://` or `https://` in any case and holds no
      ASCII whitespace. After any userinfo comes a host, either an ASCII letter or digit
      followed by ASCII letters, digits, `.`, `_`, `~` and `-`, or hex digits, `:` and `.` in
      brackets. An optional port of up to 5 digits follows, and then nothing, or a `/`, `?` or
      `#` and the rest.
    - The magnet: the `magneturl` attribute's value, else the first `enclosure` `url` (any type),
      that starts with `magnet:`.
    - The NZB link: the first `enclosure` of type `application/x-nzb` with an http(s) `url`,
      else, on a Newznab indexer, the first such `enclosure` with no `type`.
    A `type` is read without its parameters and in any case. An item's `link` element is not read.
  - `protocol`: `:usenet` for a Newznab indexer, `:torrent` for a Torznab one.

  ## Optional, nil when missing or invalid

  An attribute is a `newznab:attr` or `torznab:attr` child with both a `name`, read in any case,
  and a `value`. A number reads through `Cinder.Acquisition.Indexer.Newznab.XML.integer/1`: a
  non-negative integer of at most 18 digits, else none.

  - `size`: the first `size` attribute, else the `size` element, else the `length` of the
    enclosure the link came from, read as a non-negative integer.
  - `category_ids`: every `category` attribute that reads as a non-negative integer, in order,
    each once; nil when none does.
  - `published_at`: `pubDate`, read by `Cinder.Acquisition.Indexer.Newznab.Date`.
  - `tvdb_id`: the first `tvdbid` attribute, when it reads as a positive integer.
  - `download_url_origin`: the base URL's `Cinder.HTTPPolicy.source_origin/1` (userinfo and
    fragment dropped) when the link is an http(s) URL on the base URL's origin
    (`Cinder.HTTPPolicy.same_origin?/2`), else nil, a magnet always (#1621 point 3).

  Seeders, the info hash, grabs and freeleech are not carried. A row carries no indexer identity,
  name, source, `credentials_version` or query origin: the adapter adds the origin and Native
  stamps the rest.

  ## Limits

  Of the items that give a row, a link already given by an earlier item of the same answer is
  dropped, then the first 1,000 rows are kept (#1618 points 6 and 7). Nothing is deduped across
  answers or indexers, and no row is filtered by category.
  """

  alias Cinder.Acquisition.Indexer.Newznab.Date, as: PubDate
  alias Cinder.Acquisition.Indexer.Newznab.XML
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer

  @max_rows 1000
  @max_title_bytes 1024

  @torrent_type "application/x-bittorrent"
  @nzb_type "application/x-nzb"
  @attr_names ["newznab:attr", "torznab:attr"]

  @type row :: %{
          title: String.t(),
          download_url: String.t(),
          download_url_origin: String.t() | nil,
          protocol: :usenet | :torrent,
          size: non_neg_integer() | nil,
          category_ids: [non_neg_integer()] | nil,
          published_at: DateTime.t() | nil,
          tvdb_id: pos_integer() | nil
        }

  @doc "The rows of `items` for `indexer`; see the moduledoc."
  @spec rows([XML.element()], ConfiguredIndexer.t()) :: [row()]
  def rows(items, %ConfiguredIndexer{} = indexer) do
    protocol = protocol(indexer.type)

    items
    |> Enum.flat_map(&row(&1, protocol, indexer.base_url))
    |> Enum.uniq_by(& &1.download_url)
    |> Enum.take(@max_rows)
  end

  defp protocol(:newznab), do: :usenet
  defp protocol(:torznab), do: :torrent

  defp row(item, protocol, base_url) do
    attributes = attributes(item)

    with title when is_binary(title) <- title(item),
         {url, enclosure} <- link(item, attributes, protocol) do
      [
        %{
          title: title,
          download_url: url,
          download_url_origin: origin(url, base_url),
          protocol: protocol,
          size: size(item, attributes, enclosure),
          category_ids: category_ids(attributes),
          published_at: item |> text("pubDate") |> PubDate.parse(),
          tvdb_id: attributes |> first("tvdbid") |> integer() |> positive()
        }
      ]
    else
      _no_row -> []
    end
  end

  # --- fields ---

  defp title(item) do
    case text(item, "title") do
      nil -> nil
      text -> text |> String.trim() |> titled()
    end
  end

  defp titled(""), do: nil
  defp titled(title) when byte_size(title) > @max_title_bytes, do: nil
  defp titled(title), do: title

  # `{url, enclosure}`, the enclosure nil for a magnet from the attribute, or nil.
  defp link(item, attributes, protocol) do
    enclosures = enclosures(item)

    protocol
    |> candidates()
    |> Enum.find_value(&candidate(&1, enclosures, attributes))
  end

  defp candidates(:torrent), do: [:torrent_file, :magnet]
  defp candidates(:usenet), do: [:nzb]

  # Each protocol reads only its own file type (`candidates/1`), so an untyped enclosure is that
  # protocol's file.
  defp candidate(:torrent_file, enclosures, _attributes), do: file(enclosures, @torrent_type)
  defp candidate(:nzb, enclosures, _attributes), do: file(enclosures, @nzb_type)

  defp candidate(:magnet, enclosures, attributes) do
    case magnet(first(attributes, "magneturl")) do
      nil -> Enum.find_value(enclosures, &magnet_enclosure/1)
      url -> {url, nil}
    end
  end

  defp magnet_enclosure(enclosure) do
    if url = magnet(enclosure.url), do: {url, enclosure}
  end

  defp file(enclosures, type) do
    typed = Enum.find(enclosures, &(&1.type == type and http?(&1.url)))
    untyped = Enum.find(enclosures, &(&1.type == nil and http?(&1.url)))

    case typed || untyped do
      nil -> nil
      enclosure -> {enclosure.url, enclosure}
    end
  end

  defp magnet(url) when is_binary(url) do
    if url |> String.downcase() |> String.starts_with?("magnet:"), do: url
  end

  defp magnet(_url), do: nil

  # Scheme, optional userinfo, a host name or a bracketed IPv6 address, an optional numeric port,
  # then a path, query or fragment; no whitespace anywhere.
  @http_url Regex.compile!(
              "\\Ahttps?://(?:[^\\s/?#@]*@)?" <>
                "(?:[A-Za-z0-9][A-Za-z0-9._~-]*|\\[[0-9A-Fa-f:.]+\\])" <>
                "(?::\\d{1,5})?(?:[/?#]\\S*)?\\z",
              "i"
            )

  defp http?(url) when is_binary(url), do: url =~ @http_url
  defp http?(_url), do: false

  defp enclosures(item) do
    for {"enclosure", _attributes, _children} = element <- XML.elements(item) do
      %{
        url: element |> XML.attribute("url") |> trimmed(),
        type: element |> XML.attribute("type") |> media_type(),
        length: XML.attribute(element, "length")
      }
    end
  end

  defp media_type(nil), do: nil

  defp media_type(type) do
    case type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() do
      "" -> nil
      media_type -> media_type
    end
  end

  defp origin(url, base_url) do
    if http?(url) and HTTPPolicy.same_origin?(url, base_url),
      do: HTTPPolicy.source_origin(base_url)
  end

  defp size(item, attributes, enclosure) do
    integer(first(attributes, "size")) || integer(text(item, "size")) ||
      integer(enclosure && enclosure.length)
  end

  defp category_ids(attributes) do
    ids = for {"category", value} <- attributes, id = integer(value), uniq: true, do: id
    if ids == [], do: nil, else: ids
  end

  # --- reading ---

  # `{lowercase name, value}` of each attribute element with both, in order.
  defp attributes(item) do
    for {name, _attributes, _children} = element <- XML.elements(item),
        name in @attr_names,
        key = XML.attribute(element, "name"),
        value = XML.attribute(element, "value"),
        is_binary(key) and is_binary(value),
        do: {String.downcase(key), value}
  end

  defp first(attributes, name) do
    case List.keyfind(attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  # The text of `item`'s first child `name`: its text children joined, or nil.
  defp text(item, name) do
    case XML.child(item, name) do
      {_name, _attributes, children} -> children |> Enum.filter(&is_binary/1) |> Enum.join()
      nil -> nil
    end
  end

  defp trimmed(nil), do: nil
  defp trimmed(text), do: String.trim(text)

  defp integer(text), do: XML.integer(text)

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil
end
