defmodule CinderWeb.TranslationsCompleteTest do
  # async: false — the up-to-date check shells out to `mix gettext.extract`, which compiles into
  # the shared _build/test; running it alone (sync phase) avoids racing concurrent async tests.
  use ExUnit.Case, async: false

  # Two halves of "everything is translated":
  #
  #   1. completeness — every msgid the catalog knows has a non-empty, non-fuzzy French msgstr;
  #   2. currency — the catalog actually knows every gettext string in the source.
  #
  # Both are needed. Without (2), a `gettext("New")` that was never extracted is simply absent
  # from the French catalog, falls back to the English msgid at runtime, and (1) never notices —
  # which is exactly how the catalog silently went stale before. `no_hardcoded_strings_test`
  # covers the third leak: a literal that never reached gettext at all.

  @fr_files Path.wildcard("priv/gettext/fr/LC_MESSAGES/*.po")

  test "every French message is translated (no empty or fuzzy msgstr)" do
    untranslated = Enum.flat_map(@fr_files, &gaps/1)

    assert untranslated == [],
           "French entries still untranslated or fuzzy (run the translation pass):\n" <>
             Enum.join(untranslated, "\n")
  end

  @tag :gettext_extract
  test "the gettext catalog is up to date with the source" do
    {out, status} =
      System.cmd("mix", ["gettext.extract", "--check-up-to-date"], stderr_to_stdout: true)

    assert status == 0,
           "gettext catalog is stale — a gettext call in the source isn't extracted, so it would " <>
             "fall back to English. Run `mix gettext.extract --merge`, then translate the new " <>
             "French entries.\n\n" <> out
  end

  # --- PO inspection (Expo) --------------------------------------------------------------------

  defp gaps(file) do
    %{messages: messages} = Expo.PO.parse_file!(file)

    messages
    |> Enum.reject(&header?/1)
    |> Enum.flat_map(fn message ->
      cond do
        fuzzy?(message) -> ["#{file}: fuzzy #{inspect(msgid(message))}"]
        empty?(message) -> ["#{file}: empty #{inspect(msgid(message))}"]
        true -> []
      end
    end)
  end

  defp header?(message), do: msgid(message) == ""

  defp msgid(%Expo.Message.Singular{msgid: id}), do: IO.iodata_to_binary(id)
  defp msgid(%Expo.Message.Plural{msgid: id}), do: IO.iodata_to_binary(id)

  defp fuzzy?(message), do: Enum.any?(message.flags, &("fuzzy" in &1))

  defp empty?(%Expo.Message.Singular{msgstr: str}), do: blank?(str)

  defp empty?(%Expo.Message.Plural{msgstr: forms}),
    do: Enum.any?(forms, fn {_n, str} -> blank?(str) end)

  defp blank?(str), do: str |> IO.iodata_to_binary() |> String.trim() == ""
end
