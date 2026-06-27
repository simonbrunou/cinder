defmodule CinderWeb.NoEmDashTest do
  use ExUnit.Case, async: true

  # Guard against the em dash (—) creeping back into user-facing copy. It is a
  # banned glyph in UI copy (it also reads as machine-authored); use a period,
  # colon, comma, or parentheses instead. It is still fine in @moduledoc/@doc and
  # code comments, so this only scans inside gettext("...") calls.
  test "no em dash inside gettext copy under lib/cinder_web" do
    offenders =
      "lib/cinder_web/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> line =~ ~r/gettext\([^)]*—/u end)
        |> Enum.map(fn {_line, n} -> "#{file}:#{n}" end)
      end)

    assert offenders == [],
           "em dash (—) found in gettext copy; replace with . : , or ():\n" <>
             Enum.join(offenders, "\n")
  end
end
