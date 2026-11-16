defmodule Cinder.CodeHealth.MediaServerNameLiteralsTest do
  # A page names the media server through `Cinder.Settings.media_server_name/1`, which reads the
  # `name` of each `media_server_type` option (`Cinder.Settings.Registry`). Until #805 the movie
  # discovery, series discovery and My requests pages each spelled "Plex" and "Jellyfin" in a
  # private two-clause function, so a third option would have raised `FunctionClauseError` on any
  # page left without its clause. This fence fails a string under lib/cinder_web whose whole text
  # is an option's name: a literal, a heredoc, or a `~s`/`~S` sigil with no interpolation, with
  # the surrounding whitespace trimmed.
  #
  # Forms the walk does not follow include: the name inside a longer string, such as a gettext
  # msgid ("Sign in with Plex", which the sign-in pages keep on purpose) or HEEx template text; a
  # piece of an interpolated string ("#{x} Plex"); a charlist or an atom; a name built at run time
  # ("Pl" <> "ex"); and the `.heex` files, which the walk does not read.
  use ExUnit.Case, async: true

  @names Enum.map(Cinder.Settings.Registry.media_servers(), & &1.name)
  @sigils [:sigil_s, :sigil_S]

  test "no web-layer file spells a media server's product name" do
    hits =
      for path <- Path.wildcard("lib/cinder_web/**/*.{ex,exs}"),
          {line, name} <- path |> File.read!() |> name_literals(),
          do: "#{path}:#{line}: #{inspect(name)}"

    assert hits == [],
           "These strings spell a media server's product name:\n" <>
             Enum.join(hits, "\n") <>
             "\nCall Cinder.Settings.media_server_name/1 with the server atom instead."
  end

  test "the walk finds each form a name literal can take, and skips comments and longer text" do
    source = ~S'''
    defmodule M do
      defp name(:plex), do: "Plex"
      defp name(:jellyfin), do: "Jellyfin"

      def map, do: %{plex: ~s(Plex), jellyfin: ~S|Jellyfin|}

      def split,
        do:
          Enum.join([
            "a",
            " Plex "
          ])

      def heredoc, do: """
      Jellyfin
      """

      # "Plex" in a comment
      def longer, do: "Sign in with Plex"
      def template(assigns), do: ~H"<p>Plex</p>"
      def interpolated(x), do: "#{x} Plex"
      def built, do: "Pl" <> "ex"
      def charlist, do: ~c"Plex"
      def atom, do: :Plex
      def other, do: "Plexus"
    end
    '''

    assert name_literals(source) == [
             {2, "Plex"},
             {3, "Jellyfin"},
             {5, "Jellyfin"},
             {5, "Plex"},
             {11, "Plex"},
             {14, "Jellyfin"}
           ]
  end

  test "the names the walk looks for are every option's name" do
    assert Enum.sort(@names) == ["Jellyfin", "Plex"]
  end

  # The line and name of each string in the parsed source whose trimmed text is an option name.
  # The literal encoder wraps each literal in a `:__block__` that carries its line.
  defp name_literals(source) do
    {:ok, ast} = Code.string_to_quoted(source, literal_encoder: &{:ok, {:__block__, &2, [&1]}})

    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, hits ->
        case name_literal(node) do
          {line, name} -> {node, [{line, name} | hits]}
          nil -> {node, hits}
        end
      end)

    Enum.sort(hits)
  end

  defp name_literal({:__block__, meta, [string]}) when is_binary(string),
    do: named(meta, string)

  defp name_literal({sigil, meta, [{:<<>>, _, [string]}, _modifiers]})
       when sigil in @sigils and is_binary(string),
       do: named(meta, string)

  defp name_literal(_node), do: nil

  defp named(meta, string) do
    name = String.trim(string)
    if name in @names, do: {meta[:line], name}
  end
end
