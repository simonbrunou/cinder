defmodule Cinder.CodeHealth.AgentDocListJoinTest do
  # In CommonMark a blank line does not end a list: a list with only a blank line before the next
  # one of the same kind joins it, and both render as one loose list. On #829 (PR #1417) a
  # three-bullet list of reasons sat right above the catalog's kernel and concept list in
  # architecture.md, so the kernel and "The concepts:" rendered as the fourth and fifth reasons.
  # Both reviewers caught it with cmark; no check did. No two column-0 lists of one kind sit with
  # only a blank line between them in these docs, so this fence fails a column-0 list item whose
  # previous non-blank line belongs to a list of the same kind (`- ` bullets, or `N. ` items),
  # with a blank or whitespace-only line between them: put a lead-in paragraph between the two
  # lists. It reads column-0 list items only and counts an indented line as part of the item
  # above it. It skips ``` blocks: one at column 0 ends the list, and an indented one belongs to
  # the item above it. A column-0 thematic break (`---`, `***`, `___`, spaced or not) ends the
  # list. An unindented line right after a list line is part of that item too (a lazy
  # continuation, as AGENTS.md's "Merge authority" step 4 has), unless it opens an ATX heading
  # (one to six `#` then a space or the line's end) or a `>` block quote, which end the list.
  # It fails on the forms it does not read: the column-0 list markers `*`, `+` and `N)`, a `-`
  # or `N.` marker followed by a tab or by nothing, a ~~~ fence and a fence of four or more
  # backticks at any indent, a non-blank line (a ``` line too) indented less than the opening
  # fence of an indented ``` block, and a line that starts with `<` right after a list line,
  # which CommonMark reads as an HTML block that ends the list or as text that continues it, by
  # the tag. Forms the walk does not follow include: a nested list or any list marker indented
  # by a space or more, and a list inside a `>` block quote. It also fails forms CommonMark keeps
  # apart, which a lead-in paragraph fixes too. Among them: an `N. ` line other than `1. ` right
  # after a paragraph line, which continues the paragraph; a line indented less than the item's
  # text after a blank line, which ends the list; and an unindented line right after a block
  # inside an item, such as a ``` block, a heading or an HTML block, which starts a paragraph.
  use ExUnit.Case, async: true

  test "no two lists of the same kind in docs/agents, docs/adr, changelog.d or AGENTS.md join" do
    dirs = ["docs/agents", "docs/adr", "changelog.d"]
    paths = ["AGENTS.md" | Enum.flat_map(dirs, &Path.wildcard("#{&1}/*.md"))]

    # A wrong glob would pass the check below on nothing.
    for dir <- dirs do
      assert Enum.any?(paths, &String.starts_with?(&1, dir <> "/")), "no Markdown file in #{dir}"
    end

    found =
      for path <- paths,
          {line, what} <- path |> File.read!() |> joins(),
          do: "#{path}:#{line}: #{describe(what)}"

    assert found == [],
           "Put a lead-in paragraph between these lists, or join them on purpose without the " <>
             "blank line:\n" <> Enum.join(found, "\n")
  end

  test "a blank line between two lists of one kind joins them; other separators do not" do
    source = """
    - a
      continued

    - joins the list above
    1. an ordered list after a bullet list is a new list

    2. joins the ordered list above

    A paragraph.

    - a new list
    ## Heading

    - a new list
    ```sh
    - inside a code block

    - still inside
    ```

    - after a code block
    9. nine

    10. joins the ordered list above
    - a

      a paragraph of the item above
    - no blank line right above
    - a
    \s\s
    - a whitespace-only line is blank
    """

    assert joins(source) == [{4, :join}, {7, :join}, {24, :join}, {31, :join}]
  end

  test "an indented ``` block inside an item keeps the list open" do
    source = """
    - a
      ```sh
      - inside the item's code block

      a blank line above stays in the block
      ```

    - joins the list above
    """

    assert joins(source) == [{8, :join}]
  end

  test "a lazy continuation line keeps its item's list; a heading or block quote ends it" do
    source = """
    1. a
    lazy continuation of the item

    2. joins the list above
    - b
    #829 is text, not a heading

    - joins the list above
    - c
    ####### is text too

    - joins the list above
    - d
    # Heading

    - a new list
    - d
    ###### Heading

    - a new list
    - d
    --

    - joins the list above
    - d
    **

    - joins the list above
    - e
    #

    - a new list
    - f
    > quote

    - a new list
    """

    assert joins(source) == [{4, :join}, {8, :join}, {12, :join}, {24, :join}, {28, :join}]
  end

  test "a thematic break ends the list, a spaced `- - -` is no item, and `__` is text" do
    source = """
    - a
    ---

    - a new list
    - b
    ***

    - a new list
    - c
    _ _ _

    - a new list
    - d

    - - -

    - a new list
    - e
    __

    - joins the list above, as `__` is text
    """

    assert joins(source) == [{21, :join}]
  end

  test "the #829 draft fails, as both reviewers found it" do
    source = """
    The facade stays:

    - It keeps the Phoenix convention of one public name for a context.

    - The kernel is called by every concept and calls none of them.
    - The concepts:
      - `MovieLifecycle`: every movie status write.
    """

    assert joins(source) == [{5, :join}]
  end

  test "fails on the list markers and the lines it does not read" do
    source = """
    * star
    + plus
    1) paren
    -\ttab
    -
    1.\ttab
    1.
    ~~~
    - inside a tilde fence
      ~~~
    - a
    <https://example.com> may continue the item or open an HTML block
    - b
    lazy text keeps the item open
    <div>
    ````md
    ```sh
    ````
    """

    assert joins(source) ==
             Enum.map([1, 2, 3, 4, 5, 6, 7, 8, 10], &{&1, :unread}) ++
               [{12, :html}, {15, :html}, {16, :unread}, {18, :unread}]
  end

  test "fails an item's ``` block that the item's end closes before its closing fence" do
    source = """
    - a
      ```sh
      code
     outdented by one space, the item and its code block end here
    - b
      ```sh
      code
    - c

    - joins the list above
    - d
      ```sh
      code
    a paragraph after the list

    - starts a new list
    - e
      ```sh
      code
    ```
    a top-level code block, opened by the line above

    - f, still code
    ```

    - g

    - joins the list above
    """

    assert joins(source) ==
             [
               {4, :outdent},
               {8, :outdent},
               {10, :join},
               {14, :outdent},
               {20, :outdent},
               {28, :join}
             ]
  end

  test "misses a join inside a nested list or a block quote" do
    source = """
    - a
      - nested

      - joins the nested list above
    > - quoted
    >
    > - joins the quoted list above
    - c

     - a sibling item indented one space joins the list above
    """

    assert joins(source) == []
  end

  test "fails three forms CommonMark keeps apart" do
    source = """
    text
    2. continues the paragraph

    3. starts a new list
    10. a

      a paragraph, indented less than the item's text, ends the list

    11. starts a new list
    - a
      ```sh
      code
      ```
    a paragraph, after the item's code block

    - starts a new list
    """

    assert joins(source) == [{4, :join}, {9, :join}, {16, :join}]
  end

  defp describe(:join), do: "joins the list above it across a blank line"

  defp describe(:unread),
    do: "a list marker or fence this fence does not read: use `- `, `N. ` or ```"

  defp describe(:html),
    do: "a `<` line right after a list item: put a blank line before it"

  defp describe(:outdent),
    do: "a line indented less than the ``` fence that opens its block: indent it to the fence"

  # Walks the lines with the kind of the list the last non-blank line belongs to (`:bullet`,
  # `:ordered` or nil), whether a blank line came after it, and the indent of the open ``` block
  # (0 at column 0), or nil.
  defp joins(source) do
    {found, _state} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], {nil, false, nil}}, &step/2)

    Enum.reverse(found)
  end

  defp step({text, line} = numbered, {found, {list, blank, code}} = acc) do
    trimmed = String.trim_leading(text)
    indent = String.length(text) - String.length(trimmed)

    cond do
      String.starts_with?(trimmed, "````") -> {[{line, :unread} | found], {nil, false, nil}}
      code != nil -> in_code(numbered, acc, trimmed, indent)
      String.starts_with?(trimmed, "```") -> {found, {if(indent > 0, do: list), false, indent}}
      String.starts_with?(trimmed, "~~~") -> {[{line, :unread} | found], {nil, false, nil}}
      trimmed == "" -> {found, {list, list != nil, nil}}
      indent > 0 -> {found, {list, false, nil}}
      true -> item(text, line, found, list, blank)
    end
  end

  # A ``` block opened at column 0 ends the list; an indented one belongs to the item above it.
  # A line inside the block is code, and a ``` line closes it, unless the line is indented less
  # than the block's opening fence: the walk fails it and reads it again outside any list.
  defp in_code({_text, line} = numbered, {found, {list, _blank, code} = state}, trimmed, indent) do
    cond do
      trimmed != "" and indent < code ->
        step(numbered, {[{line, :outdent} | found], {nil, false, nil}})

      String.starts_with?(trimmed, "```") ->
        {found, {list, false, nil}}

      true ->
        {found, state}
    end
  end

  defp item(text, line, found, list, blank) do
    case kind(text) do
      :unread -> {[{line, :unread} | found], {nil, false, nil}}
      :break -> {found, {nil, false, nil}}
      nil when list != nil and not blank -> lazy(text, line, found, list)
      ^list when blank and list != nil -> {[{line, :join} | found], {list, false, nil}}
      kind -> {found, {kind, false, nil}}
    end
  end

  # An unindented line right after a list line continues that item's paragraph unless it opens
  # a block that interrupts a paragraph.
  defp lazy(text, line, found, list) do
    cond do
      String.starts_with?(text, "<") -> {[{line, :html} | found], {nil, false, nil}}
      Regex.match?(~r/^(\#{1,6}(\s|$)|>)/, text) -> {found, {nil, false, nil}}
      true -> {found, {list, false, nil}}
    end
  end

  defp kind(text) do
    cond do
      Regex.match?(~r/^((-[ \t]*){3,}|(\*[ \t]*){3,}|(_[ \t]*){3,})$/, text) -> :break
      String.starts_with?(text, "- ") -> :bullet
      Regex.match?(~r/^\d+\. /, text) -> :ordered
      Regex.match?(~r/^([-*+]|\d+[.)])(\s|$)/, text) -> :unread
      true -> nil
    end
  end
end
