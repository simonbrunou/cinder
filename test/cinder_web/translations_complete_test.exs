defmodule CinderWeb.TranslationsCompleteTest do
  # async: false — the up-to-date check shells out to `mix gettext.extract`, which compiles into
  # the shared _build/test; running it alone (sync phase) avoids racing concurrent async tests.
  use ExUnit.Case, async: false

  # Two halves of "everything is translated":
  #
  #   1. completeness — every source msgid (from the .pot) is present in fr.po with a non-empty,
  #      non-fuzzy translation;
  #   2. currency — the .pot itself knows every gettext string in the source.
  #
  # Both are needed. Iterating the .pot (not fr.po) is deliberate: it catches a string that was
  # extracted to the .pot but never `gettext.merge`d into fr.po (absent → renders the English
  # fallback, which iterating fr.po alone would never notice), and it ignores an obsolete fr.po
  # entry no longer in source (present in .po, gone from .pot → not our concern). (2) without (1)
  # misses an un-merged locale; (1) without (2) misses an un-extracted call. `no_hardcoded_strings_test`
  # covers the third leak: a literal that never reached gettext at all.

  @domains [
    {"priv/gettext/default.pot", "priv/gettext/fr/LC_MESSAGES/default.po"},
    {"priv/gettext/errors.pot", "priv/gettext/fr/LC_MESSAGES/errors.po"}
  ]

  test "every source msgid is present and translated in French (no missing/empty/fuzzy)" do
    gaps =
      Enum.flat_map(@domains, fn {pot, po} ->
        fr = po |> messages() |> Map.new(&{msgid(&1), &1})

        pot
        |> messages()
        |> Enum.reject(&header?/1)
        |> Enum.flat_map(fn message ->
          id = msgid(message)

          case Map.get(fr, id) do
            nil -> ["#{po}: missing #{inspect(id)}"]
            fr_message -> gap(po, fr_message)
          end
        end)
      end)

    assert gaps == [],
           "French catalog incomplete (run `mix gettext.extract --merge` then translate):\n" <>
             Enum.join(gaps, "\n")
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

  # --- PO/POT inspection (Expo) ----------------------------------------------------------------

  defp messages(file), do: file |> Expo.PO.parse_file!() |> Map.fetch!(:messages)

  defp gap(po, message) do
    cond do
      fuzzy?(message) -> ["#{po}: fuzzy #{inspect(msgid(message))}"]
      empty?(message) -> ["#{po}: empty #{inspect(msgid(message))}"]
      true -> []
    end
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
