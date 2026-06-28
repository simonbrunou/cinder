defmodule CinderWeb.NoEmDashTest do
  use ExUnit.Case, async: true

  # Guard against the em dash (—) creeping back into user-facing copy. It is a
  # banned glyph in UI copy (it also reads as machine-authored); use a period,
  # colon, comma, or parentheses instead. It is still fine in @moduledoc/@doc and
  # code comments, so this only scans inside the (d/n)gettext("...") families.
  #
  # Scans whole-file content rather than line-by-line: `[^)]` already spans newlines,
  # so a gettext string wrapped across physical lines with the dash on a continuation
  # line is now caught too (the prior per-line split missed exactly that).
  test "no em dash inside gettext copy under lib/cinder_web" do
    offenders =
      (Path.wildcard("lib/cinder_web/**/*.ex") ++ Path.wildcard("lib/cinder_web/**/*.heex"))
      |> Enum.flat_map(fn file ->
        content = File.read!(file)

        ~r/\bd?n?gettext\([^)]*—/u
        |> Regex.scan(content, return: :index)
        |> Enum.map(fn [{start, _len}] ->
          line = content |> binary_part(0, start) |> count_lines()
          "#{file}:#{line}"
        end)
      end)

    assert offenders == [],
           "em dash (—) found in gettext copy; replace with . : , or ():\n" <>
             Enum.join(offenders, "\n")
  end

  defp count_lines(prefix), do: length(String.split(prefix, "\n"))
end
