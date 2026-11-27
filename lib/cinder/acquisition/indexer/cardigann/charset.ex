defmodule Cinder.Acquisition.Indexer.Cardigann.Charset do
  @moduledoc ~S"""
  An encoder (text to bytes) and a decoder (bytes to text) for each `encoding` value of the v11
  Cardigann definitions (#1677, part of #1610): UTF-8 and nine legacy charsets. OTP decodes only
  Latin-1, so each other table is Cinder's own, built from the Unicode Consortium's mapping files
  (`MAPPINGS/VENDORS/MICSFT/WINDOWS/CP125x.TXT`, `CP874.TXT` and `MAPPINGS/ISO8859/8859-2.TXT`).

  - A name matches in any letter case. `tis-620` reads as `windows-874`, as .NET's
    `Encoding.GetEncoding("tis-620")` does (code page 874). `utf-8` and `utf8` are UTF-8.
  - A byte the table leaves unmapped decodes to U+FFFD, and so does a byte sequence that is not
    UTF-8. .NET decodes most such bytes of a Windows code page to a C1 control or a private-use
    character instead.
  - A character the charset cannot hold encodes as `?`, two for a character past U+FFFF, as
    .NET writes one per UTF-16 unit. .NET first tries a best-fit character for some, such as
    `a` for `ā`; Cinder does not.

  Every function is pure. The `urlencode` and `urldecode` filters call it (#1677). Since #1678
  the Cardigann adapter decodes each search page and each download page the grab reads in the
  definition's charset (`of_definition/1`), and encodes each query-string input's name and
  value in it. Path values go out in UTF-8, as Prowlarr writes them, and a grabbed torrent's
  bytes are never decoded.
  """

  # Each table's code points for the bytes 0x80 to 0xFF, in hex, FFFD where the mapping file
  # maps none.
  @tables %{
    windows_1250: ~w(20AC FFFD 201A FFFD 201E 2026 2020 2021
                  FFFD 2030 0160 2039 015A 0164 017D 0179
                  FFFD 2018 2019 201C 201D 2022 2013 2014
                  FFFD 2122 0161 203A 015B 0165 017E 017A
                  00A0 02C7 02D8 0141 00A4 0104 00A6 00A7
                  00A8 00A9 015E 00AB 00AC 00AD 00AE 017B
                  00B0 00B1 02DB 0142 00B4 00B5 00B6 00B7
                  00B8 0105 015F 00BB 013D 02DD 013E 017C
                  0154 00C1 00C2 0102 00C4 0139 0106 00C7
                  010C 00C9 0118 00CB 011A 00CD 00CE 010E
                  0110 0143 0147 00D3 00D4 0150 00D6 00D7
                  0158 016E 00DA 0170 00DC 00DD 0162 00DF
                  0155 00E1 00E2 0103 00E4 013A 0107 00E7
                  010D 00E9 0119 00EB 011B 00ED 00EE 010F
                  0111 0144 0148 00F3 00F4 0151 00F6 00F7
                  0159 016F 00FA 0171 00FC 00FD 0163 02D9),
    windows_1251: ~w(0402 0403 201A 0453 201E 2026 2020 2021
                  20AC 2030 0409 2039 040A 040C 040B 040F
                  0452 2018 2019 201C 201D 2022 2013 2014
                  FFFD 2122 0459 203A 045A 045C 045B 045F
                  00A0 040E 045E 0408 00A4 0490 00A6 00A7
                  0401 00A9 0404 00AB 00AC 00AD 00AE 0407
                  00B0 00B1 0406 0456 0491 00B5 00B6 00B7
                  0451 2116 0454 00BB 0458 0405 0455 0457
                  0410 0411 0412 0413 0414 0415 0416 0417
                  0418 0419 041A 041B 041C 041D 041E 041F
                  0420 0421 0422 0423 0424 0425 0426 0427
                  0428 0429 042A 042B 042C 042D 042E 042F
                  0430 0431 0432 0433 0434 0435 0436 0437
                  0438 0439 043A 043B 043C 043D 043E 043F
                  0440 0441 0442 0443 0444 0445 0446 0447
                  0448 0449 044A 044B 044C 044D 044E 044F),
    windows_1252: ~w(20AC FFFD 201A 0192 201E 2026 2020 2021
                  02C6 2030 0160 2039 0152 FFFD 017D FFFD
                  FFFD 2018 2019 201C 201D 2022 2013 2014
                  02DC 2122 0161 203A 0153 FFFD 017E 0178
                  00A0 00A1 00A2 00A3 00A4 00A5 00A6 00A7
                  00A8 00A9 00AA 00AB 00AC 00AD 00AE 00AF
                  00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
                  00B8 00B9 00BA 00BB 00BC 00BD 00BE 00BF
                  00C0 00C1 00C2 00C3 00C4 00C5 00C6 00C7
                  00C8 00C9 00CA 00CB 00CC 00CD 00CE 00CF
                  00D0 00D1 00D2 00D3 00D4 00D5 00D6 00D7
                  00D8 00D9 00DA 00DB 00DC 00DD 00DE 00DF
                  00E0 00E1 00E2 00E3 00E4 00E5 00E6 00E7
                  00E8 00E9 00EA 00EB 00EC 00ED 00EE 00EF
                  00F0 00F1 00F2 00F3 00F4 00F5 00F6 00F7
                  00F8 00F9 00FA 00FB 00FC 00FD 00FE 00FF),
    windows_1255: ~w(20AC FFFD 201A 0192 201E 2026 2020 2021
                  02C6 2030 FFFD 2039 FFFD FFFD FFFD FFFD
                  FFFD 2018 2019 201C 201D 2022 2013 2014
                  02DC 2122 FFFD 203A FFFD FFFD FFFD FFFD
                  00A0 00A1 00A2 00A3 20AA 00A5 00A6 00A7
                  00A8 00A9 00D7 00AB 00AC 00AD 00AE 00AF
                  00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
                  00B8 00B9 00F7 00BB 00BC 00BD 00BE 00BF
                  05B0 05B1 05B2 05B3 05B4 05B5 05B6 05B7
                  05B8 05B9 FFFD 05BB 05BC 05BD 05BE 05BF
                  05C0 05C1 05C2 05C3 05F0 05F1 05F2 05F3
                  05F4 FFFD FFFD FFFD FFFD FFFD FFFD FFFD
                  05D0 05D1 05D2 05D3 05D4 05D5 05D6 05D7
                  05D8 05D9 05DA 05DB 05DC 05DD 05DE 05DF
                  05E0 05E1 05E2 05E3 05E4 05E5 05E6 05E7
                  05E8 05E9 05EA FFFD FFFD 200E 200F FFFD),
    windows_1256: ~w(20AC 067E 201A 0192 201E 2026 2020 2021
                  02C6 2030 0679 2039 0152 0686 0698 0688
                  06AF 2018 2019 201C 201D 2022 2013 2014
                  06A9 2122 0691 203A 0153 200C 200D 06BA
                  00A0 060C 00A2 00A3 00A4 00A5 00A6 00A7
                  00A8 00A9 06BE 00AB 00AC 00AD 00AE 00AF
                  00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
                  00B8 00B9 061B 00BB 00BC 00BD 00BE 061F
                  06C1 0621 0622 0623 0624 0625 0626 0627
                  0628 0629 062A 062B 062C 062D 062E 062F
                  0630 0631 0632 0633 0634 0635 0636 00D7
                  0637 0638 0639 063A 0640 0641 0642 0643
                  00E0 0644 00E2 0645 0646 0647 0648 00E7
                  00E8 00E9 00EA 00EB 0649 064A 00EE 00EF
                  064B 064C 064D 064E 00F4 064F 0650 00F7
                  0651 00F9 0652 00FB 00FC 200E 200F 06D2),
    windows_874: ~w(20AC FFFD FFFD FFFD FFFD 2026 FFFD FFFD
                  FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD
                  FFFD 2018 2019 201C 201D 2022 2013 2014
                  FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD
                  00A0 0E01 0E02 0E03 0E04 0E05 0E06 0E07
                  0E08 0E09 0E0A 0E0B 0E0C 0E0D 0E0E 0E0F
                  0E10 0E11 0E12 0E13 0E14 0E15 0E16 0E17
                  0E18 0E19 0E1A 0E1B 0E1C 0E1D 0E1E 0E1F
                  0E20 0E21 0E22 0E23 0E24 0E25 0E26 0E27
                  0E28 0E29 0E2A 0E2B 0E2C 0E2D 0E2E 0E2F
                  0E30 0E31 0E32 0E33 0E34 0E35 0E36 0E37
                  0E38 0E39 0E3A FFFD FFFD FFFD FFFD 0E3F
                  0E40 0E41 0E42 0E43 0E44 0E45 0E46 0E47
                  0E48 0E49 0E4A 0E4B 0E4C 0E4D 0E4E 0E4F
                  0E50 0E51 0E52 0E53 0E54 0E55 0E56 0E57
                  0E58 0E59 0E5A 0E5B FFFD FFFD FFFD FFFD),
    iso_8859_2: ~w(0080 0081 0082 0083 0084 0085 0086 0087
                  0088 0089 008A 008B 008C 008D 008E 008F
                  0090 0091 0092 0093 0094 0095 0096 0097
                  0098 0099 009A 009B 009C 009D 009E 009F
                  00A0 0104 02D8 0141 00A4 013D 015A 00A7
                  00A8 0160 015E 0164 0179 00AD 017D 017B
                  00B0 0105 02DB 0142 00B4 013E 015B 02C7
                  00B8 0161 015F 0165 017A 02DD 017E 017C
                  0154 00C1 00C2 0102 00C4 0139 0106 00C7
                  010C 00C9 0118 00CB 011A 00CD 00CE 010E
                  0110 0143 0147 00D3 00D4 0150 00D6 00D7
                  0158 016E 00DA 0170 00DC 00DD 0162 00DF
                  0155 00E1 00E2 0103 00E4 013A 0107 00E7
                  010D 00E9 0119 00EB 011B 00ED 00EE 010F
                  0111 0144 0148 00F3 00F4 0151 00F6 00F7
                  0159 016F 00FA 0171 00FC 00FD 0163 02D9)
  }

  @names %{
    "utf-8" => :utf8,
    "utf8" => :utf8,
    "windows-1250" => :windows_1250,
    "windows-1251" => :windows_1251,
    "windows-1252" => :windows_1252,
    "windows-1255" => :windows_1255,
    "windows-1256" => :windows_1256,
    "windows-874" => :windows_874,
    "tis-620" => :windows_874,
    "iso-8859-1" => :iso_8859_1,
    "iso-8859-2" => :iso_8859_2
  }

  # ISO-8859-1 maps each byte to itself.
  @decode @tables
          |> Map.new(fn {charset, words} ->
            {charset, List.to_tuple(Enum.map(words, &String.to_integer(&1, 16)))}
          end)
          |> Map.put(:iso_8859_1, List.to_tuple(Enum.to_list(0x80..0xFF)))
  @encode Map.new(@decode, fn {charset, table} ->
            pairs =
              for {code_point, index} <- Enum.with_index(Tuple.to_list(table)),
                  code_point != 0xFFFD,
                  do: {code_point, 0x80 + index}

            {charset, Map.new(pairs)}
          end)

  @type t ::
          :utf8
          | :windows_1250
          | :windows_1251
          | :windows_1252
          | :windows_1255
          | :windows_1256
          | :windows_874
          | :iso_8859_1
          | :iso_8859_2

  @doc "The charsets, UTF-8 first."
  @spec charsets() :: [t()]
  def charsets, do: [:utf8 | Map.keys(@decode) |> Enum.sort()]

  @doc "The charset an `encoding` value names, in any letter case."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@names, String.downcase(name, :ascii))
  def fetch(_name), do: :error

  @doc """
  The charset of `definition`'s `encoding`, UTF-8 for a name outside the set: the load check
  reports such a definition "not supported", so no search runs it.
  """
  @spec of_definition(%{encoding: String.t() | nil}) :: t()
  def of_definition(%{encoding: name}) do
    case fetch(name) do
      {:ok, charset} -> charset
      :error -> :utf8
    end
  end

  @doc "`bytes` read in `charset` as UTF-8 text."
  @spec decode(binary(), t()) :: String.t()
  def decode(bytes, :utf8) when is_binary(bytes), do: String.replace_invalid(bytes)

  def decode(bytes, charset) when is_binary(bytes) and is_map_key(@decode, charset) do
    table = Map.fetch!(@decode, charset)
    for <<byte <- bytes>>, into: "", do: <<decode_byte(byte, table)::utf8>>
  end

  defp decode_byte(byte, _table) when byte < 0x80, do: byte
  defp decode_byte(byte, table), do: elem(table, byte - 0x80)

  @doc "`text` written in `charset`, bytes of `text` that are not UTF-8 first read as U+FFFD."
  @spec encode(String.t(), t()) :: binary()
  def encode(text, :utf8) when is_binary(text), do: String.replace_invalid(text)

  def encode(text, charset) when is_binary(text) and is_map_key(@encode, charset) do
    table = Map.fetch!(@encode, charset)

    for <<code_point::utf8 <- String.replace_invalid(text)>>,
      into: <<>>,
      do: encode_char(code_point, table)
  end

  defp encode_char(code_point, _table) when code_point < 0x80, do: <<code_point>>
  defp encode_char(code_point, _table) when code_point > 0xFFFF, do: "??"

  defp encode_char(code_point, table) do
    case Map.fetch(table, code_point) do
      {:ok, byte} -> <<byte>>
      :error -> "?"
    end
  end
end
