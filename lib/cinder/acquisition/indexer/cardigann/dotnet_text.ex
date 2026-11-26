defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetText do
  @moduledoc ~S"""
  The .NET text functions behind the Cardigann filters of #1677 (part of #1610), as Prowlarr
  calls them. Each rule comes from a `dotnet fsi` run (.NET 8.0.427), listed in the tests.

  - `query_argument/2`: Prowlarr's `ParseUtil.GetArgumentFromQueryString`, the first value of
    one query parameter, read after the first `?` and before the next `#`. Names match in any
    letter case, as `StringComparer.OrdinalIgnoreCase` does, and `+` and `%XX` decode as `QueryHelpers.ParseQuery` decodes them, a
    `%XX` run that is not UTF-8 left as written. A URL with no `?` or no such parameter is
    `:error`, where Prowlarr throws.
  - `html_decode/1` and `html_encode/1`: `WebUtility.HtmlDecode` and `HtmlEncode`.
  - `url_encode/2` and `url_decode/2`: Prowlarr's `StringExtensions.UrlEncode(encoding)` and
    `UrlDecode(encoding)`, `WebUtility.UrlEncodeToBytes` and `UrlDecodeToBytes` over the text's
    bytes in a `Cinder.Acquisition.Indexer.Cardigann.Charset`.
  - `base64url_encode/1` and `base64url_decode/1`: `WebEncoders.Base64UrlEncode` and
    `Base64UrlDecode` over UTF-8 text; bytes that are not UTF-8 decode to U+FFFD.
  - `downcase/1` and `upcase/1`: `ToLowerInvariant` and `ToUpperInvariant`, one character
    at a time, so `ß` stays `ß` and `İ` stays `İ`.
  - `strip_diacritics/1`: decomposed, each non-spacing mark of the Basic Multilingual Plane
    dropped, recomposed, as the `diacritics replace` filter does per UTF-16 unit.
  - `valid_file_name/1`: `StringUtil.MakeValidFileName(value, '_', false)` with the two
    characters .NET on Linux lists as invalid in a file name, NUL and `/`.
  - `validate/2`: the `validate` filter.

  Prowlarr's `tolower`, `toupper` and `validate` call `ToLower` and `ToUpper`, which follow the
  host's culture. Cinder reads them in the invariant culture, which a host with no locale set
  uses; an `en-US` host differs on `İ`, which it lower-cases to `i`.

  Every function is pure and returns UTF-8 text. Bytes of an argument that are not UTF-8 read
  as U+FFFD first, as .NET's text never holds them.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.Charset

  # The 253 names `WebUtility.HtmlDecode` reads (.NET 8.0.427), each with its code point.
  @entities ~w(
    AElig:00C6 Aacute:00C1 Acirc:00C2 Agrave:00C0 Alpha:0391 Aring:00C5 Atilde:00C3
    Auml:00C4 Beta:0392 Ccedil:00C7 Chi:03A7 Dagger:2021 Delta:0394 ETH:00D0
    Eacute:00C9 Ecirc:00CA Egrave:00C8 Epsilon:0395 Eta:0397 Euml:00CB Gamma:0393
    Iacute:00CD Icirc:00CE Igrave:00CC Iota:0399 Iuml:00CF Kappa:039A Lambda:039B
    Mu:039C Ntilde:00D1 Nu:039D OElig:0152 Oacute:00D3 Ocirc:00D4 Ograve:00D2
    Omega:03A9 Omicron:039F Oslash:00D8 Otilde:00D5 Ouml:00D6 Phi:03A6 Pi:03A0
    Prime:2033 Psi:03A8 Rho:03A1 Scaron:0160 Sigma:03A3 THORN:00DE Tau:03A4 Theta:0398
    Uacute:00DA Ucirc:00DB Ugrave:00D9 Upsilon:03A5 Uuml:00DC Xi:039E Yacute:00DD
    Yuml:0178 Zeta:0396 aacute:00E1 acirc:00E2 acute:00B4 aelig:00E6 agrave:00E0
    alefsym:2135 alpha:03B1 amp:0026 and:2227 ang:2220 apos:0027 aring:00E5 asymp:2248
    atilde:00E3 auml:00E4 bdquo:201E beta:03B2 brvbar:00A6 bull:2022 cap:2229
    ccedil:00E7 cedil:00B8 cent:00A2 chi:03C7 circ:02C6 clubs:2663 cong:2245 copy:00A9
    crarr:21B5 cup:222A curren:00A4 dArr:21D3 dagger:2020 darr:2193 deg:00B0 delta:03B4
    diams:2666 divide:00F7 eacute:00E9 ecirc:00EA egrave:00E8 empty:2205 emsp:2003
    ensp:2002 epsilon:03B5 equiv:2261 eta:03B7 eth:00F0 euml:00EB euro:20AC exist:2203
    fnof:0192 forall:2200 frac12:00BD frac14:00BC frac34:00BE frasl:2044 gamma:03B3
    ge:2265 gt:003E hArr:21D4 harr:2194 hearts:2665 hellip:2026 iacute:00ED icirc:00EE
    iexcl:00A1 igrave:00EC image:2111 infin:221E int:222B iota:03B9 iquest:00BF
    isin:2208 iuml:00EF kappa:03BA lArr:21D0 lambda:03BB lang:2329 laquo:00AB larr:2190
    lceil:2308 ldquo:201C le:2264 lfloor:230A lowast:2217 loz:25CA lrm:200E lsaquo:2039
    lsquo:2018 lt:003C macr:00AF mdash:2014 micro:00B5 middot:00B7 minus:2212 mu:03BC
    nabla:2207 nbsp:00A0 ndash:2013 ne:2260 ni:220B not:00AC notin:2209 nsub:2284
    ntilde:00F1 nu:03BD oacute:00F3 ocirc:00F4 oelig:0153 ograve:00F2 oline:203E
    omega:03C9 omicron:03BF oplus:2295 or:2228 ordf:00AA ordm:00BA oslash:00F8
    otilde:00F5 otimes:2297 ouml:00F6 para:00B6 part:2202 permil:2030 perp:22A5
    phi:03C6 pi:03C0 piv:03D6 plusmn:00B1 pound:00A3 prime:2032 prod:220F prop:221D
    psi:03C8 quot:0022 rArr:21D2 radic:221A rang:232A raquo:00BB rarr:2192 rceil:2309
    rdquo:201D real:211C reg:00AE rfloor:230B rho:03C1 rlm:200F rsaquo:203A rsquo:2019
    sbquo:201A scaron:0161 sdot:22C5 sect:00A7 shy:00AD sigma:03C3 sigmaf:03C2 sim:223C
    spades:2660 sub:2282 sube:2286 sum:2211 sup:2283 sup1:00B9 sup2:00B2 sup3:00B3
    supe:2287 szlig:00DF tau:03C4 there4:2234 theta:03B8 thetasym:03D1 thinsp:2009
    thorn:00FE tilde:02DC times:00D7 trade:2122 uArr:21D1 uacute:00FA uarr:2191
    ucirc:00FB ugrave:00F9 uml:00A8 upsih:03D2 upsilon:03C5 uuml:00FC weierp:2118
    xi:03BE yacute:00FD yen:00A5 yuml:00FF zeta:03B6 zwj:200D zwnj:200C
            )
            |> Map.new(fn entry ->
              [name, hex] = String.split(entry, ":")
              {name, String.to_integer(hex, 16)}
            end)

  @html_escapes %{?< => "&lt;", ?> => "&gt;", ?" => "&quot;", ?& => "&amp;", ?' => "&#39;"}
  @validate_separators [",", " ", "/", ")", "(", ".", ";", "[", "]", "\"", "|", ":"]
  # .NET's `char.IsWhiteSpace` set for `NumberStyles.Integer`'s leading and trailing white.
  @number_white ~c"\t\n\v\f\r "

  @doc "The first value of query parameter `name` in `url`, or `:error`."
  @spec query_argument(String.t(), String.t()) :: {:ok, String.t()} | :error
  def query_argument(url, name) when is_binary(url) and is_binary(name) do
    case :binary.split(String.replace_invalid(url), "?") do
      [_before, rest] ->
        [query | _fragment] = :binary.split(rest, "#")
        wanted = ordinal_upcase(String.replace_invalid(name))

        query
        |> String.replace_prefix("?", "")
        |> String.split("&", trim: true)
        |> Enum.find_value(:error, &query_value(&1, wanted))

      [_no_query] ->
        :error
    end
  end

  defp query_value(pair, wanted) do
    {key, value} =
      case :binary.split(pair, "=") do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end

    if ordinal_upcase(unescape_query(key)) == wanted, do: {:ok, unescape_query(value)}
  end

  # `StringComparer.OrdinalIgnoreCase`, which `ParseQuery`'s dictionary uses: `upcase/1`, but `ı`
  # and `ſ` keep their own letter, where the invariant culture gives `I` and `S`.
  defp ordinal_upcase(text) do
    map_chars(text, fn
      char when char in ["ı", "ſ"] -> char
      char -> upcase_char(char)
    end)
  end

  # `+` is a space, then each `%XX` run decodes as UTF-8 where it can.
  defp unescape_query(text), do: text |> String.replace("+", " ") |> unescape_data()

  defp unescape_data(text), do: text |> unescape_runs([]) |> IO.iodata_to_binary()

  defp unescape_runs(<<>>, acc), do: Enum.reverse(acc)

  defp unescape_runs(<<?%, _::binary>> = text, acc) do
    case percent_run(text, []) do
      {[], <<?%, rest::binary>>} -> unescape_runs(rest, ["%" | acc])
      {bytes, rest} -> unescape_runs(rest, [decode_run(Enum.reverse(bytes), []) | acc])
    end
  end

  defp unescape_runs(<<c::utf8, rest::binary>>, acc), do: unescape_runs(rest, [<<c::utf8>> | acc])

  defp percent_run(<<?%, a, b, rest::binary>> = text, bytes) do
    case Integer.parse(<<a, b>>, 16) do
      {byte, ""} when a not in ~c"+-" -> percent_run(rest, [{byte, <<?%, a, b>>} | bytes])
      _not_hex -> {bytes, text}
    end
  end

  defp percent_run(text, bytes), do: {bytes, text}

  # Each UTF-8 character the bytes hold, and each byte that starts none as its `%XX` text.
  defp decode_run([], acc), do: Enum.reverse(acc)

  defp decode_run([{_byte, escaped} | rest] = run, acc) do
    case utf8_char(run) do
      {:ok, char, rest} -> decode_run(rest, [char | acc])
      :error -> decode_run(rest, [escaped | acc])
    end
  end

  # A UTF-8 character is at most 4 bytes, so only the run's first 4 entries are read.
  defp utf8_char(run) do
    head = Enum.take(run, 4)

    Enum.find_value(1..length(head)//1, :error, fn size ->
      {taken, rest} = Enum.split(run, size)
      bytes = for {byte, _escaped} <- taken, into: <<>>, do: <<byte>>

      case bytes do
        <<char::utf8>> -> {:ok, <<char::utf8>>, rest}
        _not_one_char -> nil
      end
    end)
  end

  @doc "`text` with each HTML character reference .NET reads replaced by its character."
  @spec html_decode(String.t()) :: String.t()
  def html_decode(text) when is_binary(text),
    do: text |> String.replace_invalid() |> html_decode([]) |> IO.iodata_to_binary()

  defp html_decode(<<>>, acc), do: Enum.reverse(acc)

  # An `&` followed by a `;` before any other `&` opens a reference; anything else is text.
  defp html_decode(<<?&, rest::binary>>, acc) do
    case :binary.match(rest, [";", "&"]) do
      {at, 1} when binary_part(rest, at, 1) == ";" ->
        entity = binary_part(rest, 0, at)
        rest = binary_part(rest, at + 1, byte_size(rest) - at - 1)
        html_decode(rest, [reference(entity) | acc])

      _no_reference ->
        html_decode(rest, ["&" | acc])
    end
  end

  defp html_decode(<<c::utf8, rest::binary>>, acc), do: html_decode(rest, [<<c::utf8>> | acc])

  defp reference(<<?#, x, hex::binary>> = entity) when x in [?x, ?X] do
    if hex =~ ~r/\A[0-9A-Fa-f]+\z/,
      do: char_ref(code_point(hex, 16), entity),
      else: literal(entity)
  end

  defp reference(<<?#, number::binary>> = entity) when number != "" do
    trimmed =
      number |> to_charlist() |> trim_white() |> Enum.reverse() |> trim_white() |> Enum.reverse()

    case trimmed do
      [sign | digits] when sign in [?+, ?-] -> signed(sign, digits, entity)
      digits -> signed(?+, digits, entity)
    end
  end

  defp reference(name) do
    case Map.fetch(@entities, name) do
      {:ok, code_point} -> <<code_point::utf8>>
      :error -> literal(name)
    end
  end

  defp trim_white([c | rest]) when c in @number_white, do: trim_white(rest)
  defp trim_white(chars), do: chars

  defp signed(sign, digits, entity) do
    if digits != [] and Enum.all?(digits, &(&1 in ?0..?9)) do
      value = code_point(List.to_string(digits), 10)
      if sign == ?- and value != 0, do: literal(entity), else: char_ref(value, entity)
    else
      literal(entity)
    end
  end

  # Any number of leading zeros reads, as in .NET. Past 8 more digits the number is past U+10FFFF
  # in either base, so 0x110000 stands for it and a long run is never converted.
  defp code_point(digits, base) do
    significant = String.trim_leading(digits, "0")
    if byte_size(significant) > 8, do: 0x110000, else: String.to_integer("0" <> significant, base)
  end

  # .NET reads the number as an unsigned 32-bit integer and takes a scalar value, no surrogate.
  defp char_ref(value, _entity) when value < 0xD800 or value in 0xE000..0x10FFFF,
    do: <<value::utf8>>

  defp char_ref(_value, entity), do: literal(entity)

  defp literal(entity), do: "&" <> entity <> ";"

  @doc "`text` with `<`, `>`, `\"`, `&`, `'`, U+00A0 to U+00FF and each character past U+FFFF escaped."
  @spec html_encode(String.t()) :: String.t()
  def html_encode(text) when is_binary(text) do
    for <<c::utf8 <- String.replace_invalid(text)>>, into: "" do
      case @html_escapes do
        %{^c => escaped} -> escaped
        _other when c in 0xA0..0xFF or c > 0xFFFF -> "&##{c};"
        _other -> <<c::utf8>>
      end
    end
  end

  @doc "`text`'s bytes in `charset`, URL-encoded: a space as `+`, unreserved bytes as they are."
  @spec url_encode(String.t(), Charset.t()) :: String.t()
  def url_encode(text, charset) when is_binary(text) do
    for <<byte <- Charset.encode(text, charset)>>, into: "" do
      cond do
        byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-_.!*()" -> <<byte>>
        byte == ?\s -> "+"
        true -> "%" <> Base.encode16(<<byte>>)
      end
    end
  end

  @doc "`text` URL-decoded as bytes in `charset`: `+` a space, `%XX` a byte, else as written."
  @spec url_decode(String.t(), Charset.t()) :: String.t()
  def url_decode(text, charset) when is_binary(text) do
    text |> Charset.encode(charset) |> url_bytes(<<>>) |> Charset.decode(charset)
  end

  defp url_bytes(<<>>, acc), do: acc
  defp url_bytes(<<?+, rest::binary>>, acc), do: url_bytes(rest, <<acc::binary, ?\s>>)

  defp url_bytes(<<?%, a, b, rest::binary>> = text, acc) do
    case Integer.parse(<<a, b>>, 16) do
      {byte, ""} when a not in ~c"+-" -> url_bytes(rest, <<acc::binary, byte>>)
      _not_hex -> url_bytes(binary_part(text, 1, byte_size(text) - 1), <<acc::binary, ?%>>)
    end
  end

  defp url_bytes(<<byte, rest::binary>>, acc), do: url_bytes(rest, <<acc::binary, byte>>)

  @doc "`text`'s UTF-8 bytes in URL-safe base64, with no padding."
  @spec base64url_encode(String.t()) :: String.t()
  def base64url_encode(text) when is_binary(text),
    do: text |> String.replace_invalid() |> Base.url_encode64(padding: false)

  @doc """
  URL-safe or standard base64, its padding optional, read as UTF-8 text. Space, tab, CR and LF
  are skipped, but count toward the length that sets the padding, as .NET counts them. `:error`
  where .NET throws: a length of 1 more than a multiple of 4, a character outside the alphabet
  or a padding that does not fit.
  """
  @spec base64url_decode(String.t()) :: {:ok, String.t()} | :error
  def base64url_decode(text) when is_binary(text) do
    padding =
      case rem(byte_size(text), 4) do
        0 -> {:ok, ""}
        2 -> {:ok, "=="}
        3 -> {:ok, "="}
        1 -> :error
      end

    with {:ok, padding} <- padding,
         standard = String.replace(text, [" ", "\t", "\r", "\n"], ""),
         standard = standard |> String.replace("-", "+") |> String.replace("_", "/"),
         {:ok, bytes} <- Base.decode64(standard <> padding) do
      {:ok, String.replace_invalid(bytes)}
    end
  end

  @doc "`text` lower-cased one character at a time, a character with no one-character form kept."
  @spec downcase(String.t()) :: String.t()
  def downcase(text) when is_binary(text),
    do: text |> String.replace_invalid() |> map_chars(&String.downcase/1)

  @doc "`text` upper-cased one character at a time, a character with no one-character form kept."
  @spec upcase(String.t()) :: String.t()
  def upcase(text) when is_binary(text),
    do: text |> String.replace_invalid() |> map_chars(&upcase_char/1)

  # The Greek letters with ypogegrammeni have a one-character upper case (.NET's simple mapping)
  # where Elixir's full mapping gives two.
  defp upcase_char(<<c::utf8>>)
       when c in 0x1F80..0x1F87 or c in 0x1F90..0x1F97 or c in 0x1FA0..0x1FA7,
       do: <<c + 8::utf8>>

  defp upcase_char(<<c::utf8>>) when c in [0x1FB3, 0x1FC3, 0x1FF3], do: <<c + 9::utf8>>
  defp upcase_char(char), do: String.upcase(char)

  defp map_chars(text, fun) do
    for <<c::utf8 <- text>>, into: "" do
      char = <<c::utf8>>

      case fun.(char) do
        <<_one::utf8>> = mapped -> mapped
        _several -> char
      end
    end
  end

  @doc "`text` decomposed, its non-spacing marks dropped, recomposed."
  @spec strip_diacritics(String.t()) :: String.t()
  def strip_diacritics(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/(?=[\x{0}-\x{FFFF}])\p{Mn}/u, "")
    |> :unicode.characters_to_nfc_binary()
  end

  @doc "`text` with NUL and `/` replaced by `_`."
  @spec valid_file_name(String.t()) :: String.t()
  def valid_file_name(text) when is_binary(text),
    do: text |> String.replace_invalid() |> String.replace([<<0>>, "/"], "_")

  @doc """
  The words of `list` that `value` holds, in `list`'s order and each once, joined with `, `.
  Both are lower-cased and split on `, / ) ( . ; [ ] " | :`, each word trimmed and empty words
  dropped.
  """
  @spec validate(String.t(), String.t()) :: String.t()
  def validate(value, list) when is_binary(value) and is_binary(list) do
    held = MapSet.new(words(value))
    list |> words() |> Enum.uniq() |> Enum.filter(&MapSet.member?(held, &1)) |> Enum.join(", ")
  end

  defp words(text) do
    text
    |> downcase()
    |> String.split(@validate_separators)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
