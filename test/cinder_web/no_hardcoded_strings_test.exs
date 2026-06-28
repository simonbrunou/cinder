defmodule CinderWeb.NoHardcodedStringsTest do
  use ExUnit.Case, async: true

  # Guards the i18n boundary: every user-facing string must go through gettext so it can be
  # translated (en source + fr). This is the regression net for the "switched to French, still
  # see English" bug — a bare literal that bypasses gettext never reaches the catalog, so the
  # completeness check (translations_complete_test) can't see it; only a source scan can.
  #
  # Mirrors no_em_dash_test's whole-file scan style. Two classes are caught, matching the two
  # ways a literal leaks: a flash message, and a HEEx text node / translatable attribute.

  @web_files Path.wildcard("lib/cinder_web/**/*.ex") ++ Path.wildcard("lib/cinder_web/**/*.heex")

  # Attributes whose literal values render to the user — standard HTML copy attrs plus the
  # copy-bearing component attrs this app uses (`<.input label=>`, `<.empty_state message=>`, …).
  # class/name/id/phx-*/value/href etc. are deliberately excluded — they aren't copy.
  #
  # Known scope limits (regression net, not a proof): a string literal *inside* an interpolation
  # (`{"x"}`, `{cond || "x"}`) is masked away with the rest of the `{…}` and not seen; a copy attr
  # outside this list, a non-literal `put_flash` key, a single-quoted attr, or a single-line `~H"…"`
  # sigil are also out of scope. The HEEx formatter and house style keep those forms from arising.
  @translatable_attrs ~w(placeholder title aria-label alt label message hint subtitle)

  # Product/brand names and bare fragments that are identical in every locale, so a bare literal
  # is intentional. "CIN"/"DER" are the CINDER wordmark split across two spans for colour styling.
  @allow MapSet.new(~w(Cinder CINDER CIN DER TMDB Jellyfin Plex Prowlarr qBittorrent SABnzbd))

  test "no bare put_flash literal (use gettext)" do
    offenders =
      scan(@web_files, ~r/put_flash\([^)]*?:\w+\s*,\s*"/)

    assert offenders == [],
           "flash message passed as a bare literal; wrap it in gettext(\"…\"):\n" <>
             Enum.join(offenders, "\n")
  end

  test "no hardcoded user-facing strings in HEEx (use gettext)" do
    offenders = Enum.flat_map(@web_files, &scan_heex/1)

    assert offenders == [],
           "hardcoded text/attribute in HEEx; wrap it in {gettext(\"…\")}:\n" <>
             Enum.join(offenders, "\n")
  end

  # The Cinder.Settings labels render via dynamic {@field.label}, so the HEEx scan can't see into
  # them; CinderWeb.SettingsLabels.t/1 translates them at render and known/0 registers each msgid
  # for extraction. A label the domain emits but known/0 omits renders untranslated — so assert
  # the domain's label set is covered.
  test "every Cinder.Settings label is registered for translation in SettingsLabels" do
    alias Cinder.Settings

    emitted =
      (Enum.map(Settings.groups(), fn {_g, label} -> label end) ++
         Enum.map(Settings.toggles(), & &1.label) ++
         Enum.map(Settings.config_fields(), & &1.label) ++
         Enum.map(Settings.library_kinds(), & &1.label) ++
         Enum.map(Settings.library_kinds(), &"#{&1.label} library"))
      |> MapSet.new()

    missing = MapSet.difference(emitted, MapSet.new(CinderWeb.SettingsLabels.known()))

    assert MapSet.to_list(missing) == [],
           "Settings labels not registered in CinderWeb.SettingsLabels.known/0 (they would render " <>
             "untranslated):\n" <> Enum.join(MapSet.to_list(missing), "\n")
  end

  # --- flash scan: a regex over whole-file content, like no_em_dash ---------------------------

  defp scan(files, regex) do
    Enum.flat_map(files, fn file ->
      content = File.read!(file)

      regex
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [{start, _len} | _] -> "#{file}:#{line_at(content, start)}" end)
    end)
  end

  # --- HEEx scan: mask interpolations/comments (length-preserving), then flag bare text/attrs --

  defp scan_heex(file) do
    content = File.read!(file)

    content
    |> heex_regions(file)
    |> Enum.flat_map(fn {region, base} ->
      masked = mask(region)
      text_offenders(masked, content, base, file) ++ attr_offenders(masked, content, base, file)
    end)
  end

  # Whole .heex file is HEEx; in a .ex file only the ~H\"\"\"…\"\"\" sigil bodies are. Each region is
  # paired with its byte offset in the file so line numbers stay accurate. Assumes the project's
  # universal style — heredoc `~H\"\"\"…\"\"\"` sigils and double-quoted attributes; a single-line
  # `~H"…"` or single-quoted attr would not be scanned (the HEEx formatter keeps both in style).
  defp heex_regions(content, file) do
    if String.ends_with?(file, ".heex") do
      [{content, 0}]
    else
      ~r/~H"""(.*?)"""/s
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [_full, {start, len}] -> {binary_part(content, start, len), start} end)
    end
  end

  # Replace HEEx `{…}` interpolations (balanced, so `%{}` nests), EEx `<% %>`, and comments with
  # equal-byte-length spaces. Offsets (line numbers) are preserved while their contents can no
  # longer be mistaken for hardcoded copy — a wrapped `{gettext("x")}` simply masks to spaces.
  defp mask(region) do
    region
    |> mask_pattern(~r/<%!--.*?--%>/s)
    |> mask_pattern(~r/<!--.*?-->/s)
    |> mask_pattern(~r/<%.*?%>/s)
    |> mask_braces()
  end

  defp mask_pattern(s, re),
    do: Regex.replace(re, s, fn m -> blank(m) end)

  defp mask_braces(s) do
    {out, _depth} =
      s
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn
        "{", {acc, depth} -> {[blank("{") | acc], depth + 1}
        "}", {acc, depth} -> {[blank("}") | acc], max(depth - 1, 0)}
        g, {acc, depth} when depth > 0 -> {[blank(g) | acc], depth}
        g, {acc, depth} -> {[g | acc], depth}
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp blank(g), do: String.duplicate(" ", byte_size(g))

  # Mask the tags too, leaving only rendered text (between AND at the edges of tags — copy like
  # `<.icon /> Save changes`, which a `>…<` match would miss because it has no trailing `<`). Any
  # 2+ letter word that survives is hardcoded copy (a wrapped `{gettext(...)}` already masked away).
  defp text_offenders(masked, content, base, file) do
    text = masked |> mask_tags() |> mask_pattern(~r/&[a-z0-9#]+;/i)

    ~r/\p{L}{2,}/u
    |> Regex.scan(text, return: :index)
    |> Enum.reject(fn [{s, len}] -> MapSet.member?(@allow, binary_part(text, s, len)) end)
    |> Enum.map(fn [{s, _len}] -> "#{file}:#{line_at(content, base + s)}" end)
    |> Enum.uniq()
  end

  # Quote-aware so a literal `>` inside a double-quoted attribute value (e.g. a Tailwind
  # child-combinator class `[&>tbody]:…`) doesn't end the tag early and leak the remainder as text.
  defp mask_tags(s), do: mask_pattern(s, ~r/<(?:[^>"]|"[^"]*")*>/s)

  # `(?<![-\w])` so `data-title="…"` / `xtitle="…"` don't match the bare `title` attribute.
  defp attr_offenders(masked, content, base, file) do
    ~r/(?<![-\w])(?:#{Enum.join(@translatable_attrs, "|")})\s*=\s*"([^"]*)"/
    |> Regex.scan(masked, return: :index)
    |> Enum.filter(fn [_full, {s, len}] -> meaningful?(binary_part(masked, s, len)) end)
    |> Enum.map(fn [_full, {s, _len}] -> "#{file}:#{line_at(content, base + s)}" end)
  end

  # A string is user-facing copy if, after dropping HTML entities and product names, it still has
  # a word of two or more letters. Punctuation, digits, single letters, and brand-only text pass.
  defp meaningful?(text) do
    text
    |> String.replace(~r/&[a-z0-9#]+;/i, " ")
    |> then(&Regex.scan(~r/\p{L}{2,}/u, &1))
    |> List.flatten()
    |> Enum.reject(&MapSet.member?(@allow, &1))
    |> Enum.any?()
  end

  defp line_at(content, byte_offset),
    do: content |> binary_part(0, byte_offset) |> count_lines()

  defp count_lines(prefix), do: length(String.split(prefix, "\n"))
end
