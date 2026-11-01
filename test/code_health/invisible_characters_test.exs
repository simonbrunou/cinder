defmodule Cinder.CodeHealth.InvisibleCharactersTest do
  # On #1040 a byte order mark meant for `String.trim_leading/2` landed in a test as the
  # character itself, not an escape: the Edit tool decodes a backslash-u escape in what it writes.
  # The diff and the file showed an empty string, and only a later read of the bytes found it.
  # This fence fails on a character that renders as nothing or as a plain space anywhere in the
  # Elixir sources, comments and strings included, since in any of them a reviewer cannot see it.
  # It scans characters, not syntax: no context makes such a character visible.
  use ExUnit.Case, async: true

  # A control character other than tab, line feed and a carriage return that ends its line; a
  # format character such as a zero-width space, a joiner or a byte order mark; a space other
  # than U+0020; a line or paragraph separator; any other default-ignorable code point, such as a
  # Hangul filler. A variation selector (U+FE00 to U+FE0F) passes: it styles the character before
  # it, as U+FE0F does in the Discord notifier's emoji.
  @invisible ~r/(?![\t\n ]|\r\z|[\x{FE00}-\x{FE0F}])[\p{Cc}\p{Cf}\p{Zs}\p{Zl}\p{Zp}\p{DI}]/u

  test "no Elixir source holds an invisible character" do
    paths =
      Path.wildcard("{lib,test,config,priv,scripts}/**/*.{ex,exs,heex}") ++
        Path.wildcard("*.exs", match_dot: true)

    found =
      for path <- paths,
          problem <- path |> File.read!() |> invisible_characters(),
          do: "#{path}:#{problem}"

    assert paths != []

    assert found == [],
           "These characters render as nothing or as a plain space. Write each as " <>
             "<<0x...::utf8>> in Elixir code, as \\x{...} in a regex and as &nbsp; or an " <>
             "{<<0x...::utf8>>} expression in HEEx, forms no tool decodes on the way in:\n  " <>
             Enum.join(found, "\n  ")
  end

  test "the scan names each invisible character by line and code point" do
    source =
      Enum.join(
        [
          "a = \"@" <> <<0x200B::utf8>> <> "here\"",
          "# a no-break" <> <<0xA0::utf8>> <> "space in a comment",
          <<0xFEFF::utf8>> <> "b = 1",
          "c = \"" <> <<0x2028::utf8>> <> "\" <> \"" <> <<0x1B>> <> "\"",
          "d = \"" <> <<0x3164::utf8>> <> "\" # a Hangul filler",
          "e = \"a\rb\""
        ],
        "\n"
      )

    assert invisible_characters(source) == [
             "1: U+200B",
             "2: U+00A0",
             "3: U+FEFF",
             "4: U+2028",
             "4: U+001B",
             "5: U+3164",
             "6: U+000D"
           ]
  end

  test "the scan skips visible characters, tabs, plain spaces and variation selectors" do
    source =
      "\tname = \"Amélie — 2 films\" # déjà vu\r\nemoji = \"" <>
        <<0x1F3AC::utf8, 0x26A0::utf8, 0xFE0F::utf8>> <>
        "\"\naccent = \"e" <> <<0x0301::utf8>> <> "\"\n"

    assert invisible_characters(source) == []
  end

  defp invisible_characters(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      for [char] <- Regex.scan(@invisible, line) do
        code = char |> String.to_charlist() |> hd() |> Integer.to_string(16)
        "#{number}: U+#{String.pad_leading(code, 4, "0")}"
      end
    end)
  end
end
