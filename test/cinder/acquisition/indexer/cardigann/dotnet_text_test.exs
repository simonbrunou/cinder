defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetTextTest do
  # Each expected value ran in `dotnet fsi` (.NET 8.0.427) on 2026-11-26, except three kinds,
  # each marked by a comment where it sits: the best-fit row of code page 1251, the runs at the
  # body cap and the arguments that are not UTF-8, which .NET text cannot hold. Each ran through
  # the call Prowlarr b0b5774's filter makes: `ParseUtil.GetArgumentFromQueryString`,
  # `WebUtility.HtmlDecode` and `HtmlEncode`, `StringExtensions.UrlEncode` and `UrlDecode` with
  # `Encoding.UTF8` or code page 1251, `WebEncoders.Base64UrlEncode` and `Base64UrlDecode`,
  # `ToLowerInvariant` and `ToUpperInvariant`, the `diacritics replace` loop,
  # `Path.GetInvalidFileNameChars` on Linux and the `validate` filter. Prowlarr's casing calls
  # `ToLower` and `ToUpper` under the host's culture; Cinder reads them in the invariant one.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Cardigann.DotnetText

  describe "query_argument/2" do
    test "gives the first value of a parameter, its name in any case and its text decoded" do
      for {url, name, expected} <- [
            {"http://x/d?id=5&b=2", "id", "5"},
            {"http://x/d?id=5&id=6", "id", "5"},
            {"http://x/d?id=1#x", "id", "1"},
            {"http://x/d?ID=9", "id", "9"},
            {"http://x/d?id=a+b%20c%zz", "id", "a b c%zz"},
            {"http://x/d?id", "id", ""},
            {"http://x/d?id=", "id", ""},
            {"http://x/d?&id=3&", "id", "3"},
            {"http://x/#?id=4", "id", "4"},
            {"?id=%C3%A9%E9", "id", "é%E9"},
            {"http://x/d?id=1;b=2", "id", "1;b=2"},
            {"http://x/d?%69d=8", "id", "8"},
            {"http://x/d??id=1", "id", "1"},
            {"http://x/d?=5&id=2", "id", "2"},
            {"http://x/d?id=1&&id=2", "id", "1"},
            {"http://x/d?id=%2", "id", "%2"},
            {"http://x/d?id=%E2%82", "id", "%E2%82"},
            {"http://x/d?id=%E2%82%AC%FF", "id", "€%FF"},
            {"http://x/d?id=%ED%A0%80", "id", "%ED%A0%80"},
            {"http://x/d?%49D=7", "id", "7"},
            {"http://x/d?id=a=b", "id", "a=b"},
            {"http://x/d?id=%+41", "id", "% 41"},
            {"http://x/d?id=%-1", "id", "%-1"},
            # `%-F` is no escape, so the three bytes after it stay escaped; read as a byte, `-F`
            # would be 0xF1 and start a character with them.
            {"http://x/d?id=%-F%9F%98%80", "id", "%-F%9F%98%80"}
          ] do
        assert {url, DotnetText.query_argument(url, name)} == {url, {:ok, expected}}
      end
    end

    test "is :error where Prowlarr throws: no query, or no such parameter" do
      for {url, name} <- [
            {"http://x/d?id=5", "nope"},
            {"http://x/d", "id"},
            {"http://x/d?a=1#id=7", "id"},
            {"http://x/d?a=1?id=2", "id"},
            {"http://x/d? id=3", "id"},
            {"http://x/d?id =3", "id"},
            {"http://x/d?\u0131d=1", "ID"},
            {"http://x/d?\u017Fs=1", "SS"},
            {"http://x/d?\u00DF=1", "SS"}
          ] do
        assert {url, DotnetText.query_argument(url, name)} == {url, :error}
      end
    end
  end

  describe "html_decode/1" do
    test "reads the named, decimal and hex references .NET reads" do
      for {text, expected} <- [
            {"&amp;&lt;&gt;&quot;&#39;&apos;", "&<>\"''"},
            {"&#233;&#xE9;&#XE9;&eacute;&Eacute;&nbsp;", "ééééÉ\u00A0"},
            {"&#x1F600;", "😀"},
            {"&#0;", <<0>>},
            {"&# 65;", "A"},
            {"&#+65;", "A"},
            {"&#-0;", <<0>>},
            {"&#65 ;", "A"},
            {"&#\t65\t;", "A"},
            {"&#\v65;", "A"},
            {"&# +65;", "A"},
            {"&#0065;", "A"},
            {"&#x0041;", "A"},
            {"&#x00000041;", "A"},
            {"&#0000000065;", "A"},
            {"&#xE000;", ""},
            {"&#xfffe;", <<0xFFFE::utf8>>},
            {"&#X41;", "A"},
            {"&#1114111;", <<0x10FFFF::utf8>>},
            {"&#" <> String.duplicate("0", 40) <> "65;", "A"},
            {"&#x" <> String.duplicate("0", 40) <> "41;", "A"},
            {"&#-" <> String.duplicate("0", 30) <> ";", <<0>>}
          ] do
        assert {text, DotnetText.html_decode(text)} == {text, expected}
      end
    end

    test "leaves a reference it cannot read, and an & with no ; before the next &, as text" do
      for {text, expected} <- [
            {"&unknown;&amp&#;&#x;", "&unknown;&amp&#;&#x;"},
            {"&#xD800;&#1114112;", "&#xD800;&#1114112;"},
            {"&AMP;&#65&lt", "&AMP;&#65&lt"},
            {"a &amp;amp; b", "a &amp; b"},
            {"&#x 41;&#x+41;&#4294967296;&#xFFFFFFFF;",
             "&#x 41;&#x+41;&#4294967296;&#xFFFFFFFF;"},
            {"&#x110000;&#xDFFF;&#65.0;&#1,000;&#x1g;",
             "&#x110000;&#xDFFF;&#65.0;&#1,000;&#x1g;"},
            {"&#٣;", "&#٣;"},
            {"&#+ 65;", "&#+ 65;"},
            {"&#\u00A065;", "&#\u00A065;"},
            {"&", "&"},
            {"&;", "&;"},
            {"&#", "&#"},
            {"a&b;c", "a&b;c"},
            {"&foo &amp;", "&foo &"},
            {"&a&amp;", "&a&"},
            {"&#65&amp;", "&#65&"},
            {"x&amp&lt;", "x&amp<"}
          ] do
        assert {text, DotnetText.html_decode(text)} == {text, expected}
      end
    end

    test "leaves a number too large for a code point as text, however long" do
      # `dotnet fsi` (.NET 8.0.427) on 2026-11-26 leaves the 20-digit, 400-digit and 40-digit
      # hex references as written. The two runs at the body cap did not run in .NET; each once
      # raised building the integer.
      cap = Indexer.max_response_bytes()

      for text <- [
            "&#99999999999999999999;",
            "&#" <> String.duplicate("9", 400) <> ";",
            "&#x" <> String.duplicate("F", 40) <> ";",
            "&#" <> String.duplicate("9", cap) <> ";",
            "&#x" <> String.duplicate("F", cap) <> ";"
          ] do
        assert DotnetText.html_decode(text) == text
      end
    end

    test "reads each of the 253 names .NET reads, in their letter case only" do
      assert DotnetText.html_decode("&hearts;&Dagger;&dagger;&thetasym;&zwj;") ==
               "♥‡†ϑ\u200D"

      assert DotnetText.html_decode("&Hearts;&NBSP;&apos") == "&Hearts;&NBSP;&apos"
    end
  end

  test "html_encode/1 escapes five characters, U+00A0 to U+00FF and characters past U+FFFF" do
    for {text, expected} <- [
          {"<a href=\"x\">&'</a>", "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;"},
          {"éÿ\u00A0\u009FĀ€", "&#233;&#255;&#160;\u009FĀ€"},
          {"😀", "&#128512;"},
          {"\t\n\r\u007F" <> <<0>>, "\t\n\r\u007F" <> <<0>>},
          {"\u0080\u009F\u00A0ÿ", "\u0080\u009F&#160;&#255;"},
          {"�x", "�x"}
        ] do
      assert {text, DotnetText.html_encode(text)} == {text, expected}
    end
  end

  describe "url_encode/2 and url_decode/2" do
    test "encode the text's bytes in the charset, a space as +, unreserved bytes as they are" do
      ascii = "a b+c&d=e/f?g#h~i*j(k)l!m-n_o.p'q\"r%s"
      expected = "a+b%2Bc%26d%3De%2Ff%3Fg%23h%7Ei*j(k)l!m-n_o.p%27q%22r%25s"

      for {text, charset, out} <- [
            {ascii, :utf8, expected},
            {ascii, :windows_1251, expected},
            {"Дюна é", :utf8, "%D0%94%D1%8E%D0%BD%D0%B0+%C3%A9"},
            {"Дюна", :windows_1251, "%C4%FE%ED%E0"},
            {"€😀", :utf8, "%E2%82%AC%F0%9F%98%80"},
            {"€😀", :windows_1251, "%88%3F%3F"},
            {"\t\n", :windows_1251, "%09%0A"}
          ] do
        assert {text, charset, DotnetText.url_encode(text, charset)} == {text, charset, out}
      end
    end

    test "encode a character the charset lacks as ?, where .NET's best fit writes a near letter" do
      # .NET gives `e` for `é` in code page 1251 (`%C4%FE%ED%E0+e`); Cinder keeps no best-fit
      # table and writes `?`, as .NET does for a character with no near letter, such as `😀`.
      assert DotnetText.url_encode("Дюна é", :windows_1251) == "%C4%FE%ED%E0+%3F"
    end

    test "decode + as a space and %XX as a byte in the charset, anything else as written" do
      for {text, charset, out} <- [
            {"%D0%94%D1%8E+x", :utf8, "Дю x"},
            {"%D0%94%D1%8E+x", :windows_1251, "Р”СЋ x"},
            {"%C4%FE%ED%E0", :utf8, "����"},
            {"%C4%FE%ED%E0", :windows_1251, "Дюна"},
            {"%zz%4", :windows_1251, "%zz%4"},
            {"%", :utf8, "%"},
            {"a%2", :utf8, "a%2"},
            {"%e9", :utf8, "�"},
            {"%e9", :windows_1251, "й"},
            {"%FF%FE", :windows_1251, "яю"},
            {"%c0%E1", :windows_1251, "Аб"},
            {"Дюна%20", :utf8, "Дюна "},
            {"Дюна%20", :windows_1251, "Дюна "},
            {"%u0041", :utf8, "%u0041"},
            {"%-1", :utf8, "%-1"},
            {"%+1", :utf8, "% 1"},
            {"a%2B", :utf8, "a+"},
            {"%2b%2B", :utf8, "++"},
            {"100%", :utf8, "100%"},
            {"%%41", :utf8, "%A"}
          ] do
        assert {text, charset, DotnetText.url_decode(text, charset)} == {text, charset, out}
      end
    end
  end

  describe "base64url_encode/1 and base64url_decode/1" do
    test "encode UTF-8 bytes URL-safe with no padding" do
      for {text, out} <- [
            {"??>", "Pz8-"},
            {"??~", "Pz9-"},
            {"Дюна", "0JTRjtC90LA"},
            {"", ""},
            {"a", "YQ"}
          ] do
        assert {text, DotnetText.base64url_encode(text)} == {text, out}
      end
    end

    test "decode either alphabet, padding optional, bytes that are not UTF-8 as U+FFFD" do
      for {text, out} <- [
            {"Pz8-", "??>"},
            {"Pz8_", "???"},
            {"Pz8+", "??>"},
            {"Pz8/", "???"},
            {"Pz8", "??"},
            {"YQ", "a"},
            {"YQ==", "a"},
            {"YQ=", "a"},
            {"YR==", "a"},
            {"_w", "�"},
            {"", ""},
            {"0JTRjtC90LA", "Дюна"},
            {"YWJj\r\n\r\n", "abc"},
            {"Q U J D ", "ABC"},
            {"YWJj    ", "abc"}
          ] do
        assert {text, DotnetText.base64url_decode(text)} == {text, {:ok, out}}
      end
    end

    test "is :error where .NET throws" do
      # Space, tab, CR and LF count toward the length that sets the padding, then drop out; any
      # other white space is outside the alphabet.
      for text <- [
            "Pz8-=",
            "a",
            "abc*",
            " YQ",
            "Y Q",
            "Y===",
            "YWJj\n",
            "YW\tJj",
            "YW I",
            "YQ\n\n",
            "YQ= ",
            "YWI \r\n",
            "YWJj\v\v\v\v",
            "YWJj\f\f\f\f",
            "YWJj\u00A0\u00A0\u00A0\u00A0"
          ] do
        assert {text, DotnetText.base64url_decode(text)} == {text, :error}
      end
    end
  end

  test "downcase/1 and upcase/1 map one character to one, as the invariant culture does" do
    for {text, lower, upper} <- [
          {"ß", "ß", "ß"},
          {"ΣΑΣ", "σασ", "ΣΑΣ"},
          {"İ", "İ", "İ"},
          {"ǅ", "ǆ", "Ǆ"},
          {"ﬀ", "ﬀ", "ﬀ"},
          {"ŉ", "ŉ", "ŉ"},
          {"ᾳ", "ᾳ", "ᾼ"},
          {"Straße ΑΒΓ", "straße αβγ", "STRAßE ΑΒΓ"},
          {"\u1F80\u1F97\u1FA7", "\u1F80\u1F97\u1FA7", "\u1F88\u1F9F\u1FAF"},
          {"\u1F87\u1F90\u1FA0", "\u1F87\u1F90\u1FA0", "\u1F8F\u1F98\u1FA8"},
          {"\u1FC3\u1FF3\u1F88\u1FB2", "\u1FC3\u1FF3\u1F80\u1FB2", "\u1FCC\u1FFC\u1F88\u1FB2"}
        ] do
      assert {text, DotnetText.downcase(text), DotnetText.upcase(text)} == {text, lower, upper}
    end
  end

  test "strip_diacritics/1 drops the non-spacing marks of the decomposed text" do
    for {text, out} <- [
          {"ŠĐĆŽ - šđčćž", "SĐCZ - sđccz"},
          {"Ångström", "Angstrom"},
          {"é⃝", "e⃝"},
          {"ǅ", "ǅ"},
          {"ẛ̣", "ſ"},
          # .NET reads a character past U+FFFF as two surrogates, never a mark: U+1D167 stays.
          {"a\u{1D167}", "a\u{1D167}"},
          {"e\u0301\u{1D167}", "e\u{1D167}"}
        ] do
      assert {text, DotnetText.strip_diacritics(text)} == {text, out}
    end
  end

  test "each function reads bytes that are not UTF-8 as U+FFFD, and never raises" do
    # .NET text cannot hold these bytes, so no row here ran in .NET.
    bad = <<"a", 0xFF, "/">>
    fffd = "a\uFFFD/"

    for {name, fun, out} <- [
          {:query_argument, &DotnetText.query_argument(<<"?id=", &1::binary>>, <<"id", 0xFF>>),
           :error},
          {:query_argument, &DotnetText.query_argument(<<"?id=", &1::binary>>, "id"),
           {:ok, fffd}},
          {:html_decode, &DotnetText.html_decode/1, fffd},
          {:html_encode, &DotnetText.html_encode/1, fffd},
          {:url_encode, &DotnetText.url_encode(&1, :windows_1251), "a%3F%2F"},
          {:url_decode, &DotnetText.url_decode(&1, :utf8), fffd},
          {:base64url_encode, &DotnetText.base64url_encode/1,
           Base.url_encode64(fffd, padding: false)},
          {:base64url_decode, &DotnetText.base64url_decode/1, :error},
          {:downcase, &DotnetText.downcase/1, fffd},
          {:upcase, &DotnetText.upcase/1, "A\uFFFD/"},
          {:strip_diacritics, &DotnetText.strip_diacritics/1, fffd},
          {:valid_file_name, &DotnetText.valid_file_name/1, "a\uFFFD_"},
          {:validate, &DotnetText.validate(&1, "a\uFFFD"), "a\uFFFD"}
        ] do
      assert {name, fun.(bad)} == {name, out}
    end
  end

  test "valid_file_name/1 replaces NUL and / with _" do
    assert DotnetText.valid_file_name("a/b" <> <<0>> <> "c\\d:e") == "a_b_c\\d:e"
  end

  test "validate/2 keeps the list's words the value holds, in list order, each once" do
    for {list, value, out} <- [
          {"1080p, 720p, 2160p, x265", "Movie.2160P.x265 (1080p) 2160p", "1080p, 2160p, x265"},
          {"FLAC,MP3", "mp3|flac|mp3", "flac, mp3"},
          {"a", "b", ""},
          {"", "x", ""},
          {"x\ty", "x\ty", "x\ty"},
          {"mp3, flac, mp3", "mp3", "mp3"},
          {"x", "x\t", "x"},
          {"x\t", "x", "x"},
          {"x\u00A0", "x", "x"},
          {"ΣΑΣ", "σας", ""}
        ] do
      assert {list, value, DotnetText.validate(value, list)} == {list, value, out}
    end
  end
end
