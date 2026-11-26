defmodule Cinder.Acquisition.Indexer.Cardigann.CharsetTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Charset

  # The text of the bytes 0x80 to 0xFF in each charset, U+FFFD where the Unicode mapping file
  # maps none. Written from Python 3's own codecs (cp125x, cp874, iso8859_1, iso8859_2), which
  # agree with the Unicode files on every byte; the module's tables were built from the files.
  @expected [
    {"windows-1250",
     "\u{20AC}\u{FFFD}\u{201A}\u{FFFD}\u{201E}\u{2026}\u{2020}\u{2021}" <>
       "\u{FFFD}\u{2030}\u{0160}\u{2039}\u{015A}\u{0164}\u{017D}\u{0179}" <>
       "\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{FFFD}\u{2122}\u{0161}\u{203A}\u{015B}\u{0165}\u{017E}\u{017A}" <>
       "\u{00A0}\u{02C7}\u{02D8}\u{0141}\u{00A4}\u{0104}\u{00A6}\u{00A7}" <>
       "\u{00A8}\u{00A9}\u{015E}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{017B}" <>
       "\u{00B0}\u{00B1}\u{02DB}\u{0142}\u{00B4}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{00B8}\u{0105}\u{015F}\u{00BB}\u{013D}\u{02DD}\u{013E}\u{017C}" <>
       "\u{0154}\u{00C1}\u{00C2}\u{0102}\u{00C4}\u{0139}\u{0106}\u{00C7}" <>
       "\u{010C}\u{00C9}\u{0118}\u{00CB}\u{011A}\u{00CD}\u{00CE}\u{010E}" <>
       "\u{0110}\u{0143}\u{0147}\u{00D3}\u{00D4}\u{0150}\u{00D6}\u{00D7}" <>
       "\u{0158}\u{016E}\u{00DA}\u{0170}\u{00DC}\u{00DD}\u{0162}\u{00DF}" <>
       "\u{0155}\u{00E1}\u{00E2}\u{0103}\u{00E4}\u{013A}\u{0107}\u{00E7}" <>
       "\u{010D}\u{00E9}\u{0119}\u{00EB}\u{011B}\u{00ED}\u{00EE}\u{010F}" <>
       "\u{0111}\u{0144}\u{0148}\u{00F3}\u{00F4}\u{0151}\u{00F6}\u{00F7}" <>
       "\u{0159}\u{016F}\u{00FA}\u{0171}\u{00FC}\u{00FD}\u{0163}\u{02D9}"},
    {"windows-1251",
     "\u{0402}\u{0403}\u{201A}\u{0453}\u{201E}\u{2026}\u{2020}\u{2021}" <>
       "\u{20AC}\u{2030}\u{0409}\u{2039}\u{040A}\u{040C}\u{040B}\u{040F}" <>
       "\u{0452}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{FFFD}\u{2122}\u{0459}\u{203A}\u{045A}\u{045C}\u{045B}\u{045F}" <>
       "\u{00A0}\u{040E}\u{045E}\u{0408}\u{00A4}\u{0490}\u{00A6}\u{00A7}" <>
       "\u{0401}\u{00A9}\u{0404}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{0407}" <>
       "\u{00B0}\u{00B1}\u{0406}\u{0456}\u{0491}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{0451}\u{2116}\u{0454}\u{00BB}\u{0458}\u{0405}\u{0455}\u{0457}" <>
       "\u{0410}\u{0411}\u{0412}\u{0413}\u{0414}\u{0415}\u{0416}\u{0417}" <>
       "\u{0418}\u{0419}\u{041A}\u{041B}\u{041C}\u{041D}\u{041E}\u{041F}" <>
       "\u{0420}\u{0421}\u{0422}\u{0423}\u{0424}\u{0425}\u{0426}\u{0427}" <>
       "\u{0428}\u{0429}\u{042A}\u{042B}\u{042C}\u{042D}\u{042E}\u{042F}" <>
       "\u{0430}\u{0431}\u{0432}\u{0433}\u{0434}\u{0435}\u{0436}\u{0437}" <>
       "\u{0438}\u{0439}\u{043A}\u{043B}\u{043C}\u{043D}\u{043E}\u{043F}" <>
       "\u{0440}\u{0441}\u{0442}\u{0443}\u{0444}\u{0445}\u{0446}\u{0447}" <>
       "\u{0448}\u{0449}\u{044A}\u{044B}\u{044C}\u{044D}\u{044E}\u{044F}"},
    {"windows-1252",
     "\u{20AC}\u{FFFD}\u{201A}\u{0192}\u{201E}\u{2026}\u{2020}\u{2021}" <>
       "\u{02C6}\u{2030}\u{0160}\u{2039}\u{0152}\u{FFFD}\u{017D}\u{FFFD}" <>
       "\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{02DC}\u{2122}\u{0161}\u{203A}\u{0153}\u{FFFD}\u{017E}\u{0178}" <>
       "\u{00A0}\u{00A1}\u{00A2}\u{00A3}\u{00A4}\u{00A5}\u{00A6}\u{00A7}" <>
       "\u{00A8}\u{00A9}\u{00AA}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{00AF}" <>
       "\u{00B0}\u{00B1}\u{00B2}\u{00B3}\u{00B4}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{00B8}\u{00B9}\u{00BA}\u{00BB}\u{00BC}\u{00BD}\u{00BE}\u{00BF}" <>
       "\u{00C0}\u{00C1}\u{00C2}\u{00C3}\u{00C4}\u{00C5}\u{00C6}\u{00C7}" <>
       "\u{00C8}\u{00C9}\u{00CA}\u{00CB}\u{00CC}\u{00CD}\u{00CE}\u{00CF}" <>
       "\u{00D0}\u{00D1}\u{00D2}\u{00D3}\u{00D4}\u{00D5}\u{00D6}\u{00D7}" <>
       "\u{00D8}\u{00D9}\u{00DA}\u{00DB}\u{00DC}\u{00DD}\u{00DE}\u{00DF}" <>
       "\u{00E0}\u{00E1}\u{00E2}\u{00E3}\u{00E4}\u{00E5}\u{00E6}\u{00E7}" <>
       "\u{00E8}\u{00E9}\u{00EA}\u{00EB}\u{00EC}\u{00ED}\u{00EE}\u{00EF}" <>
       "\u{00F0}\u{00F1}\u{00F2}\u{00F3}\u{00F4}\u{00F5}\u{00F6}\u{00F7}" <>
       "\u{00F8}\u{00F9}\u{00FA}\u{00FB}\u{00FC}\u{00FD}\u{00FE}\u{00FF}"},
    {"windows-1255",
     "\u{20AC}\u{FFFD}\u{201A}\u{0192}\u{201E}\u{2026}\u{2020}\u{2021}" <>
       "\u{02C6}\u{2030}\u{FFFD}\u{2039}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" <>
       "\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{02DC}\u{2122}\u{FFFD}\u{203A}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" <>
       "\u{00A0}\u{00A1}\u{00A2}\u{00A3}\u{20AA}\u{00A5}\u{00A6}\u{00A7}" <>
       "\u{00A8}\u{00A9}\u{00D7}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{00AF}" <>
       "\u{00B0}\u{00B1}\u{00B2}\u{00B3}\u{00B4}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{00B8}\u{00B9}\u{00F7}\u{00BB}\u{00BC}\u{00BD}\u{00BE}\u{00BF}" <>
       "\u{05B0}\u{05B1}\u{05B2}\u{05B3}\u{05B4}\u{05B5}\u{05B6}\u{05B7}" <>
       "\u{05B8}\u{05B9}\u{FFFD}\u{05BB}\u{05BC}\u{05BD}\u{05BE}\u{05BF}" <>
       "\u{05C0}\u{05C1}\u{05C2}\u{05C3}\u{05F0}\u{05F1}\u{05F2}\u{05F3}" <>
       "\u{05F4}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" <>
       "\u{05D0}\u{05D1}\u{05D2}\u{05D3}\u{05D4}\u{05D5}\u{05D6}\u{05D7}" <>
       "\u{05D8}\u{05D9}\u{05DA}\u{05DB}\u{05DC}\u{05DD}\u{05DE}\u{05DF}" <>
       "\u{05E0}\u{05E1}\u{05E2}\u{05E3}\u{05E4}\u{05E5}\u{05E6}\u{05E7}" <>
       "\u{05E8}\u{05E9}\u{05EA}\u{FFFD}\u{FFFD}\u{200E}\u{200F}\u{FFFD}"},
    {"windows-1256",
     "\u{20AC}\u{067E}\u{201A}\u{0192}\u{201E}\u{2026}\u{2020}\u{2021}" <>
       "\u{02C6}\u{2030}\u{0679}\u{2039}\u{0152}\u{0686}\u{0698}\u{0688}" <>
       "\u{06AF}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{06A9}\u{2122}\u{0691}\u{203A}\u{0153}\u{200C}\u{200D}\u{06BA}" <>
       "\u{00A0}\u{060C}\u{00A2}\u{00A3}\u{00A4}\u{00A5}\u{00A6}\u{00A7}" <>
       "\u{00A8}\u{00A9}\u{06BE}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{00AF}" <>
       "\u{00B0}\u{00B1}\u{00B2}\u{00B3}\u{00B4}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{00B8}\u{00B9}\u{061B}\u{00BB}\u{00BC}\u{00BD}\u{00BE}\u{061F}" <>
       "\u{06C1}\u{0621}\u{0622}\u{0623}\u{0624}\u{0625}\u{0626}\u{0627}" <>
       "\u{0628}\u{0629}\u{062A}\u{062B}\u{062C}\u{062D}\u{062E}\u{062F}" <>
       "\u{0630}\u{0631}\u{0632}\u{0633}\u{0634}\u{0635}\u{0636}\u{00D7}" <>
       "\u{0637}\u{0638}\u{0639}\u{063A}\u{0640}\u{0641}\u{0642}\u{0643}" <>
       "\u{00E0}\u{0644}\u{00E2}\u{0645}\u{0646}\u{0647}\u{0648}\u{00E7}" <>
       "\u{00E8}\u{00E9}\u{00EA}\u{00EB}\u{0649}\u{064A}\u{00EE}\u{00EF}" <>
       "\u{064B}\u{064C}\u{064D}\u{064E}\u{00F4}\u{064F}\u{0650}\u{00F7}" <>
       "\u{0651}\u{00F9}\u{0652}\u{00FB}\u{00FC}\u{200E}\u{200F}\u{06D2}"},
    {"windows-874",
     "\u{20AC}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{2026}\u{FFFD}\u{FFFD}" <>
       "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" <>
       "\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}" <>
       "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" <>
       "\u{00A0}\u{0E01}\u{0E02}\u{0E03}\u{0E04}\u{0E05}\u{0E06}\u{0E07}" <>
       "\u{0E08}\u{0E09}\u{0E0A}\u{0E0B}\u{0E0C}\u{0E0D}\u{0E0E}\u{0E0F}" <>
       "\u{0E10}\u{0E11}\u{0E12}\u{0E13}\u{0E14}\u{0E15}\u{0E16}\u{0E17}" <>
       "\u{0E18}\u{0E19}\u{0E1A}\u{0E1B}\u{0E1C}\u{0E1D}\u{0E1E}\u{0E1F}" <>
       "\u{0E20}\u{0E21}\u{0E22}\u{0E23}\u{0E24}\u{0E25}\u{0E26}\u{0E27}" <>
       "\u{0E28}\u{0E29}\u{0E2A}\u{0E2B}\u{0E2C}\u{0E2D}\u{0E2E}\u{0E2F}" <>
       "\u{0E30}\u{0E31}\u{0E32}\u{0E33}\u{0E34}\u{0E35}\u{0E36}\u{0E37}" <>
       "\u{0E38}\u{0E39}\u{0E3A}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{0E3F}" <>
       "\u{0E40}\u{0E41}\u{0E42}\u{0E43}\u{0E44}\u{0E45}\u{0E46}\u{0E47}" <>
       "\u{0E48}\u{0E49}\u{0E4A}\u{0E4B}\u{0E4C}\u{0E4D}\u{0E4E}\u{0E4F}" <>
       "\u{0E50}\u{0E51}\u{0E52}\u{0E53}\u{0E54}\u{0E55}\u{0E56}\u{0E57}" <>
       "\u{0E58}\u{0E59}\u{0E5A}\u{0E5B}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"},
    {"ISO-8859-1",
     "\u{0080}\u{0081}\u{0082}\u{0083}\u{0084}\u{0085}\u{0086}\u{0087}" <>
       "\u{0088}\u{0089}\u{008A}\u{008B}\u{008C}\u{008D}\u{008E}\u{008F}" <>
       "\u{0090}\u{0091}\u{0092}\u{0093}\u{0094}\u{0095}\u{0096}\u{0097}" <>
       "\u{0098}\u{0099}\u{009A}\u{009B}\u{009C}\u{009D}\u{009E}\u{009F}" <>
       "\u{00A0}\u{00A1}\u{00A2}\u{00A3}\u{00A4}\u{00A5}\u{00A6}\u{00A7}" <>
       "\u{00A8}\u{00A9}\u{00AA}\u{00AB}\u{00AC}\u{00AD}\u{00AE}\u{00AF}" <>
       "\u{00B0}\u{00B1}\u{00B2}\u{00B3}\u{00B4}\u{00B5}\u{00B6}\u{00B7}" <>
       "\u{00B8}\u{00B9}\u{00BA}\u{00BB}\u{00BC}\u{00BD}\u{00BE}\u{00BF}" <>
       "\u{00C0}\u{00C1}\u{00C2}\u{00C3}\u{00C4}\u{00C5}\u{00C6}\u{00C7}" <>
       "\u{00C8}\u{00C9}\u{00CA}\u{00CB}\u{00CC}\u{00CD}\u{00CE}\u{00CF}" <>
       "\u{00D0}\u{00D1}\u{00D2}\u{00D3}\u{00D4}\u{00D5}\u{00D6}\u{00D7}" <>
       "\u{00D8}\u{00D9}\u{00DA}\u{00DB}\u{00DC}\u{00DD}\u{00DE}\u{00DF}" <>
       "\u{00E0}\u{00E1}\u{00E2}\u{00E3}\u{00E4}\u{00E5}\u{00E6}\u{00E7}" <>
       "\u{00E8}\u{00E9}\u{00EA}\u{00EB}\u{00EC}\u{00ED}\u{00EE}\u{00EF}" <>
       "\u{00F0}\u{00F1}\u{00F2}\u{00F3}\u{00F4}\u{00F5}\u{00F6}\u{00F7}" <>
       "\u{00F8}\u{00F9}\u{00FA}\u{00FB}\u{00FC}\u{00FD}\u{00FE}\u{00FF}"},
    {"ISO-8859-2",
     "\u{0080}\u{0081}\u{0082}\u{0083}\u{0084}\u{0085}\u{0086}\u{0087}" <>
       "\u{0088}\u{0089}\u{008A}\u{008B}\u{008C}\u{008D}\u{008E}\u{008F}" <>
       "\u{0090}\u{0091}\u{0092}\u{0093}\u{0094}\u{0095}\u{0096}\u{0097}" <>
       "\u{0098}\u{0099}\u{009A}\u{009B}\u{009C}\u{009D}\u{009E}\u{009F}" <>
       "\u{00A0}\u{0104}\u{02D8}\u{0141}\u{00A4}\u{013D}\u{015A}\u{00A7}" <>
       "\u{00A8}\u{0160}\u{015E}\u{0164}\u{0179}\u{00AD}\u{017D}\u{017B}" <>
       "\u{00B0}\u{0105}\u{02DB}\u{0142}\u{00B4}\u{013E}\u{015B}\u{02C7}" <>
       "\u{00B8}\u{0161}\u{015F}\u{0165}\u{017A}\u{02DD}\u{017E}\u{017C}" <>
       "\u{0154}\u{00C1}\u{00C2}\u{0102}\u{00C4}\u{0139}\u{0106}\u{00C7}" <>
       "\u{010C}\u{00C9}\u{0118}\u{00CB}\u{011A}\u{00CD}\u{00CE}\u{010E}" <>
       "\u{0110}\u{0143}\u{0147}\u{00D3}\u{00D4}\u{0150}\u{00D6}\u{00D7}" <>
       "\u{0158}\u{016E}\u{00DA}\u{0170}\u{00DC}\u{00DD}\u{0162}\u{00DF}" <>
       "\u{0155}\u{00E1}\u{00E2}\u{0103}\u{00E4}\u{013A}\u{0107}\u{00E7}" <>
       "\u{010D}\u{00E9}\u{0119}\u{00EB}\u{011B}\u{00ED}\u{00EE}\u{010F}" <>
       "\u{0111}\u{0144}\u{0148}\u{00F3}\u{00F4}\u{0151}\u{00F6}\u{00F7}" <>
       "\u{0159}\u{016F}\u{00FA}\u{0171}\u{00FC}\u{00FD}\u{0163}\u{02D9}"}
  ]

  @high for byte <- 0x80..0xFF, into: <<>>, do: <<byte>>

  defp charset!(name) do
    {:ok, charset} = Charset.fetch(name)
    charset
  end

  describe "decode/2 and encode/2" do
    test "every byte from 0x80 to 0xFF of each legacy charset, both ways" do
      for {name, expected} <- @expected do
        charset = charset!(name)
        assert {name, Charset.decode(@high, charset)} == {name, expected}

        mapped =
          for {char, byte} <- Enum.zip(String.codepoints(expected), 0x80..0xFF),
              char != "�",
              into: <<>>,
              do: <<byte>>

        assert {name, Charset.encode(Charset.decode(mapped, charset), charset)} == {name, mapped}
      end
    end

    test "tis-620 reads as windows-874, as .NET's code page 874" do
      # .NET 8.0.427: Encoding.GetEncoding("tis-620").CodePage is 874.
      assert Charset.fetch("tis-620") == Charset.fetch("windows-874")
      assert Charset.decode(<<0x80, 0xA1>>, charset!("TIS-620")) == "€ก"
    end

    test "windows-1251 reads 0xC0 as А (U+0410), which OTP cannot decode" do
      assert_raise ArgumentError, fn -> :unicode.characters_to_binary(<<0xC0>>, :cp1251) end
      assert Charset.decode(<<0xC0>>, charset!("windows-1251")) == "А"
      assert Charset.encode("Дюна", charset!("windows-1251")) == <<0xC4, 0xFE, 0xED, 0xE0>>
    end

    test "an unmapped byte decodes to U+FFFD in each charset that has one" do
      for {name, byte} <- [
            {"windows-1250", 0x81},
            {"windows-1251", 0x98},
            {"windows-1252", 0x81},
            {"windows-1255", 0xCA},
            {"windows-874", 0xDB}
          ] do
        assert {name, Charset.decode(<<?a, byte, ?b>>, charset!(name))} == {name, "a�b"}
      end
    end

    test "a character the charset cannot hold encodes as ?, two past U+FFFF" do
      # .NET 8.0.427 writes ? for Ж in windows-1252 and ?? for 😀 (two UTF-16 units) in each.
      for {name, _expected} <- @expected do
        charset = charset!(name)
        assert {name, Charset.encode("a沙b😀", charset)} == {name, "a?b??"}
      end

      assert Charset.encode("Ж", charset!("windows-1252")) == "?"
      assert Charset.encode("€", charset!("ISO-8859-1")) == "?"
    end

    test "U+FFFD, and a byte of the text that is not UTF-8, encode as ?" do
      # .NET 8.0.427 writes ? for U+FFFD in each; its text is never bytes that are not UTF-8.
      for {name, _expected} <- @expected do
        charset = charset!(name)
        assert {name, Charset.encode("a\uFFFDb", charset)} == {name, "a?b"}
        assert {name, Charset.encode(<<?a, 0xFF, ?b>>, charset)} == {name, "a?b"}
      end

      assert Charset.encode(<<?a, 0xFF, ?b>>, :utf8) == "a\uFFFDb"
    end

    test "ASCII passes through each charset unchanged" do
      ascii = for byte <- 0..0x7F, into: <<>>, do: <<byte>>

      for charset <- Charset.charsets() do
        assert {charset, Charset.decode(ascii, charset)} == {charset, ascii}
        assert {charset, Charset.encode(ascii, charset)} == {charset, ascii}
      end
    end

    test "UTF-8 passes text through and decodes bytes that are not UTF-8 as U+FFFD" do
      assert Charset.encode("Дюна 😀", :utf8) == "Дюна 😀"
      assert Charset.decode("Дюна", :utf8) == "Дюна"
      assert Charset.decode(<<?a, 0xFF, ?b, 0xC3>>, :utf8) == "a�b�"
    end
  end

  describe "fetch/1" do
    test "reads each v11 name in any letter case" do
      for name <- ~w(windows-1250 windows-1251 windows-1252 windows-1255 windows-1256
                     windows-874 ISO-8859-1 iso-8859-1 ISO-8859-2 tis-620 UTF-8 utf8) do
        assert {name, Charset.fetch(name)} == {name, Charset.fetch(String.upcase(name))}
        assert {name, Charset.fetch(String.downcase(name))} == {name, Charset.fetch(name)}
        assert {name, match?({:ok, _}, Charset.fetch(name))} == {name, true}
      end

      assert Charset.fetch("Windows-1251") == {:ok, :windows_1251}
    end

    test "any other name, or a value that is not text, is :error" do
      assert Charset.fetch("koi8-r") == :error
      assert Charset.fetch("windows-1253") == :error
      assert Charset.fetch(nil) == :error
    end

    test "lists UTF-8 and the nine names' eight tables" do
      assert Charset.charsets() ==
               ~w(utf8 iso_8859_1 iso_8859_2 windows_1250 windows_1251 windows_1252 windows_1255
                  windows_1256 windows_874)a
    end
  end
end
