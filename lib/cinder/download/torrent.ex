defmodule Cinder.Download.Torrent do
  @moduledoc """
  Computes the qBittorrent torrent id from `.torrent` bytes.

  The infohash covers the bencoded `info` value **exactly as it appears in the
  file** (byte-for-byte, not a re-encode). v1 torrents use their SHA-1 hash;
  v2 and hybrid torrents use the first 20 bytes of their SHA-256 hash, which is
  qBittorrent's Web API torrent id.
  """

  @doc """
  Returns `{:ok, hex}` (lowercase 40-char hex) or `{:error, :bad_torrent}` for
  malformed / non-bencode input.
  """
  @spec infohash(binary) :: {:ok, String.t()} | {:error, :bad_torrent}
  def infohash(bin) when is_binary(bin) do
    case info_span(bin) do
      {:ok, {start, len}} ->
        info = binary_part(bin, start, len)

        case hash_algorithm(info) do
          {:ok, algorithm} ->
            digest = :crypto.hash(algorithm, info) |> binary_part(0, 20)
            {:ok, Base.encode16(digest, case: :lower)}

          :error ->
            {:error, :bad_torrent}
        end

      :error ->
        {:error, :bad_torrent}
    end
  rescue
    # :binary.at/2 raises on out-of-range; str-length parse can raise on
    # malformed input; treat any of it as a bad torrent rather than crashing.
    _ -> {:error, :bad_torrent}
  end

  # qBittorrent uses libtorrent's canonical id: truncated v2 when present,
  # otherwise v1. Unknown metainfo versions cannot safely be treated as v1.
  defp hash_algorithm(info) do
    case decode(info, 0) do
      {%{"meta version" => 2}, next} when next == byte_size(info) ->
        {:ok, :sha256}

      {%{"meta version" => _unsupported}, _next} ->
        :error

      {%{}, next} when next == byte_size(info) ->
        {:ok, :sha}

      _ ->
        :error
    end
  end

  @doc """
  Extracts every tracker/web-seed URL embedded in a `.torrent`'s metainfo
  (`announce`, `announce-list`, `url-list`, `httpseeds`) as a flat list of strings, so a
  caller can vet them before handing the file to a download client. Returns `[]` for
  anything that can't be decoded — `infohash/1` is what gates whether the file counts as a
  valid torrent at all; this is best-effort on top of that.
  """
  @spec embedded_urls(binary) :: [String.t()]
  def embedded_urls(bin) when is_binary(bin) do
    case decode(bin, 0) do
      {%{} = top, _next} ->
        top
        |> take_url_fields()
        |> List.flatten()
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  rescue
    # Same rationale as infohash/1: never raise on attacker-controlled bytes.
    _ -> []
  end

  defp take_url_fields(dict) do
    [
      Map.get(dict, "announce"),
      Map.get(dict, "announce-list"),
      Map.get(dict, "url-list"),
      Map.get(dict, "httpseeds")
    ]
  end

  @url_fields ~w(announce announce-list url-list httpseeds)

  @doc """
  Rewrites the `.torrent`'s endpoint fields (`announce`, `announce-list`, `url-list`,
  `httpseeds`), keeping only URLs `keep?.(url)` approves; a field left empty is omitted.
  Every other top-level value — the `info` dict above all — is spliced through
  byte-verbatim, so the torrent id is unchanged. Returns `{:ok, bytes}` or
  `{:error, :bad_torrent}`.
  """
  @spec sanitize_embedded_urls(binary, (String.t() -> boolean)) ::
          {:ok, binary} | {:error, :bad_torrent}
  def sanitize_embedded_urls(<<?d, _::binary>> = bin, keep?) do
    {:ok, IO.iodata_to_binary(rebuild_dict(bin, 1, keep?, ["d"]))}
  rescue
    # Same rationale as infohash/1: never raise on attacker-controlled bytes.
    _ -> {:error, :bad_torrent}
  end

  def sanitize_embedded_urls(_bin, _keep?), do: {:error, :bad_torrent}

  defp rebuild_dict(bin, off, keep?, acc) do
    case :binary.at(bin, off) do
      ?e ->
        Enum.reverse(["e" | acc])

      _ ->
        {klen, kstart} = str_len(bin, off, 0)
        key = binary_part(bin, kstart, klen)
        vstart = kstart + klen
        vend = skip(bin, vstart)
        rebuild_dict(bin, vend, keep?, rebuild_pair(bin, key, off, vstart, vend, keep?, acc))
    end
  end

  # One key/value pair's contribution to the rebuilt dict: url fields re-encode filtered
  # (or vanish), everything else splices through byte-verbatim.
  defp rebuild_pair(bin, key, _off, vstart, _vend, keep?, acc) when key in @url_fields do
    {value, _next} = decode(bin, vstart)

    case filter_url_field(key, value, keep?) do
      :drop -> acc
      {:keep, kept} -> [encode(kept), encode(key) | acc]
    end
  end

  defp rebuild_pair(bin, _key, off, _vstart, vend, _keep?, acc),
    do: [binary_part(bin, off, vend - off) | acc]

  # announce (and url-list's legacy single-string form): one URL, kept or dropped whole.
  defp filter_url_field(_key, url, keep?) when is_binary(url),
    do: if(keep?.(url), do: {:keep, url}, else: :drop)

  # announce-list is a list of tiers (lists of URLs); empty tiers vanish with their URLs.
  defp filter_url_field("announce-list", tiers, keep?) when is_list(tiers) do
    kept =
      tiers
      |> Enum.map(fn
        tier when is_list(tier) -> Enum.filter(tier, &(is_binary(&1) and keep?.(&1)))
        _other -> []
      end)
      |> Enum.reject(&(&1 == []))

    if kept == [], do: :drop, else: {:keep, kept}
  end

  # url-list / httpseeds: flat lists of URLs.
  defp filter_url_field(_key, urls, keep?) when is_list(urls) do
    kept = Enum.filter(urls, &(is_binary(&1) and keep?.(&1)))
    if kept == [], do: :drop, else: {:keep, kept}
  end

  # A malformed endpoint field (wrong bencode type) carries nothing vettable — drop it.
  defp filter_url_field(_key, _value, _keep?), do: :drop

  defp encode(value) when is_binary(value),
    do: [Integer.to_string(byte_size(value)), ":", value]

  defp encode(value) when is_integer(value), do: ["i", Integer.to_string(value), "e"]
  defp encode(values) when is_list(values), do: ["l", Enum.map(values, &encode/1), "e"]

  defp encode(%{} = dict),
    do: ["d", dict |> Enum.sort() |> Enum.map(fn {k, v} -> [encode(k), encode(v)] end), "e"]

  # A generic bencode decoder (distinct from the byte-span walker below, which only ever
  # needs to locate — not decode — the `info` value). Recursion depth tracks bencode nesting
  # depth, same ceiling as `skip_container/2` below; both rely on the caller bounding total
  # input size (qBittorrent caps a fetched .torrent at 10 MB) rather than limiting nesting.
  defp decode(bin, off) do
    case :binary.at(bin, off) do
      ?i ->
        close = find(bin, off + 1, ?e)
        {int, ""} = bin |> binary_part(off + 1, close - off - 1) |> Integer.parse()
        {int, close + 1}

      ?l ->
        decode_list(bin, off + 1, [])

      ?d ->
        decode_dict(bin, off + 1, %{})

      c when c in ?0..?9 ->
        {len, start} = str_len(bin, off, 0)
        {binary_part(bin, start, len), start + len}
    end
  end

  defp decode_list(bin, off, acc) do
    case :binary.at(bin, off) do
      ?e ->
        {Enum.reverse(acc), off + 1}

      _ ->
        {value, next} = decode(bin, off)
        decode_list(bin, next, [value | acc])
    end
  end

  defp decode_dict(bin, off, acc) do
    case :binary.at(bin, off) do
      ?e ->
        {acc, off + 1}

      _ ->
        {klen, kstart} = str_len(bin, off, 0)
        key = binary_part(bin, kstart, klen)
        {value, next} = decode(bin, kstart + klen)
        decode_dict(bin, next, Map.put(acc, key, value))
    end
  end

  # Top-level must be a dict; walk its key/value pairs for "info".
  defp info_span(<<?d, _::binary>> = bin), do: walk(bin, 1)
  defp info_span(_), do: :error

  defp walk(bin, off) do
    case :binary.at(bin, off) do
      ?e -> :error
      _ -> walk_pair(bin, off)
    end
  end

  defp walk_pair(bin, off) do
    {klen, kstart} = str_len(bin, off, 0)
    key = binary_part(bin, kstart, klen)
    vstart = kstart + klen
    vend = skip(bin, vstart)

    if key == "info",
      do: info_value_span(bin, vstart, vend),
      else: walk(bin, vend)
  end

  # The info value must be a bencoded dict; any other type is malformed.
  defp info_value_span(bin, vstart, vend) do
    if :binary.at(bin, vstart) == ?d,
      do: {:ok, {vstart, vend - vstart}},
      else: :error
  end

  # Offset just past the bencoded value starting at `off`.
  defp skip(bin, off) do
    case :binary.at(bin, off) do
      ?i ->
        find(bin, off + 1, ?e) + 1

      ?l ->
        skip_container(bin, off + 1)

      ?d ->
        skip_container(bin, off + 1)

      c when c in ?0..?9 ->
        {len, rest} = str_len(bin, off, 0)
        rest + len
    end
  end

  defp skip_container(bin, off) do
    case :binary.at(bin, off) do
      ?e -> off + 1
      _ -> skip_container(bin, skip(bin, off))
    end
  end

  # Parse a `<len>:` byte-string prefix → {len, offset_after_colon}.
  defp str_len(bin, off, acc) do
    case :binary.at(bin, off) do
      ?: -> {acc, off + 1}
      d when d in ?0..?9 -> str_len(bin, off + 1, acc * 10 + (d - ?0))
    end
  end

  defp find(bin, off, ch) do
    if :binary.at(bin, off) == ch, do: off, else: find(bin, off + 1, ch)
  end
end
