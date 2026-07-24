defmodule Cinder.Download.Torrent do
  @moduledoc """
  Computes a torrent's BitTorrent v1 infohash from its `.torrent` bytes.

  The v1 infohash is the SHA-1 of the bencoded `info` value **exactly as it
  appears in the file** (byte-for-byte, not a re-encode), so this is a minimal
  bencode value-walker that locates the byte span of the top-level `info` value
  and hashes that span. v2/hybrid (SHA-256) infohashes are out of scope.
  """

  @doc """
  Returns `{:ok, hex}` (lowercase 40-char hex) or `{:error, :bad_torrent}` for
  malformed / non-bencode input.
  """
  @spec infohash(binary) :: {:ok, String.t()} | {:error, :bad_torrent}
  def infohash(bin) when is_binary(bin) do
    case info_span(bin) do
      {:ok, {start, len}} ->
        digest = :crypto.hash(:sha, binary_part(bin, start, len))
        {:ok, Base.encode16(digest, case: :lower)}

      :error ->
        {:error, :bad_torrent}
    end
  rescue
    # :binary.at/2 raises on out-of-range; str-length parse can raise on
    # malformed input; treat any of it as a bad torrent rather than crashing.
    _ -> {:error, :bad_torrent}
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
