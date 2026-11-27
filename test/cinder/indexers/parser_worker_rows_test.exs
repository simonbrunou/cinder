defmodule Cinder.Indexers.ParserWorkerRowsTest do
  # `rows.after` and `dateheaders` in the real worker (#1679): the merged tree and the walk back
  # to a date header row.
  use ExUnit.Case, async: true

  alias Cinder.Indexers.ParserWorker

  @deadline 30_000

  defp field(name, attrs \\ []) do
    Map.merge(%{name: name, selector: nil, attribute: nil, remove: [], case: []}, Map.new(attrs))
  end

  defp header(attrs),
    do: Map.merge(%{selector: nil, attribute: nil, remove: [], case: []}, Map.new(attrs))

  defp run(plan, html), do: ParserWorker.run(html, plan, deadline_ms: @deadline)

  defp table(rows), do: "<html><body><table>" <> Enum.join(rows) <> "</table></body></html>"

  defp dated do
    table([
      ~s(<tr class="r"><td class="t">Before</td></tr>),
      ~s(<tr class="h"><td colspan="2"><b>Monday 2026-11-23</b></td></tr>),
      ~s(<tr class="r"><td class="t">One</td></tr>),
      ~s(<tr class="r"><td class="t">Two</td></tr>),
      ~s(<tr class="h"><td colspan="2"><b>Tuesday 2026-11-24</b></td></tr>),
      ~s(<tr class="r"><td class="t">Three</td></tr>)
    ])
  end

  describe "rows.after" do
    @fields [
      %{name: "title", selector: "td.t", attribute: nil, remove: [], case: []},
      %{name: "size", selector: "td.s", attribute: nil, remove: [], case: []}
    ]

    test "after: 1 merges each row with the next: four rows read as two" do
      html =
        table([
          ~s(<tr class="r"><td class="t">One</td></tr>),
          ~s(<tr class="r"><td class="s">1 GB</td></tr>),
          ~s(<tr class="r"><td class="t">Two</td></tr>),
          ~s(<tr class="r"><td class="s">2 GB</td></tr>)
        ])

      assert run(%{rows: "tr.r", fields: @fields, after: 1}, html) ==
               {:ok,
                [
                  [{"title", "One"}, {"size", "1 GB"}],
                  [{"title", "Two"}, {"size", "2 GB"}]
                ]}

      # The control: with no merge each row reads alone.
      assert {:ok, [_, _, _, _]} = run(%{rows: "tr.r", fields: @fields}, html)
    end

    test "five rows give three: the last group is left unmerged" do
      rows =
        for {t, s} <- [{"One", "1"}, {"Two", "2"}],
            do:
              ~s(<tr class="r"><td class="t">#{t}</td></tr><tr class="r"><td class="s">#{s} GB</td></tr>)

      html = table(rows ++ [~s(<tr class="r"><td class="t">Three</td></tr>)])

      assert {:ok, [_one, _two, [{"title", "Three"}, {"size", nil}]]} =
               run(%{rows: "tr.r", fields: @fields, after: 1}, html)
    end

    test "a field reads the merged children by position, and :contains sees the merged text" do
      html =
        table([
          ~s(<tr class="r"><td>One</td><td>a</td></tr>),
          ~s(<tr class="r"><td>x</td><td>free</td></tr>)
        ])

      fields = [
        field("fourth", selector: "td:nth-child(4)"),
        field("free", selector: ~S|td:contains("free")|)
      ]

      assert run(%{rows: "tr.r", fields: fields, after: 1}, html) ==
               {:ok, [[{"fourth", "free"}, {"free", "free"}]]}
    end
  end

  describe "dateheaders" do
    test "each row reads the header row before it, and a row before any header reads nil" do
      plan = %{
        rows: "tr.r",
        fields: [field("title", selector: "td.t")],
        dateheader: header(selector: "td[colspan] > b")
      }

      assert run(plan, dated()) ==
               {:ok,
                [
                  [{"title", "Before"}, {:dateheader, nil}],
                  [{"title", "One"}, {:dateheader, "Monday 2026-11-23"}],
                  [{"title", "Two"}, {:dateheader, "Monday 2026-11-23"}],
                  [{"title", "Three"}, {:dateheader, "Tuesday 2026-11-24"}]
                ]}
    end

    test "a row with no previous sibling walks on from its parent's previous sibling" do
      html = """
      <html><body>
      <div class="day"><b>2026-11-23</b></div>
      <div class="group"><p class="r">One</p><p class="r">Two</p></div>
      </body></html>
      """

      plan = %{rows: "p.r", fields: [], dateheader: header(selector: "div.day b")}

      assert run(plan, html) ==
               {:ok, [[{:dateheader, "2026-11-23"}], [{:dateheader, "2026-11-23"}]]}
    end

    test "an element whose attribute is missing does not qualify, and the walk goes on" do
      html =
        table([
          ~s(<tr class="h"><td><b data-day="2026-11-23">x</b></td></tr>),
          ~s(<tr class="h"><td><b>no attribute</b></td></tr>),
          ~s(<tr class="r"><td>One</td></tr>)
        ])

      plan = %{rows: "tr.r", fields: [], dateheader: header(selector: "b", attribute: "data-day")}
      assert run(plan, html) == {:ok, [[{:dateheader, "2026-11-23"}]]}
    end

    test "with after, the emptied rows stay in the tree and the walk passes them" do
      html =
        table([
          ~s(<tr class="h"><td colspan="2"><b>2026-11-23</b></td></tr>),
          ~s(<tr class="r"><td class="t">One</td></tr>),
          ~s(<tr class="r"><td class="s">1 GB</td></tr>),
          ~s(<tr class="r"><td class="t">Two</td></tr>),
          ~s(<tr class="r"><td class="s">2 GB</td></tr>)
        ])

      plan = %{
        rows: "tr.r",
        fields: [field("title", selector: "td.t")],
        after: 1,
        dateheader: header(selector: "td[colspan] > b")
      }

      assert run(plan, html) ==
               {:ok,
                [
                  [{"title", "One"}, {:dateheader, "2026-11-23"}],
                  [{"title", "Two"}, {:dateheader, "2026-11-23"}]
                ]}
    end

    test "a date header selector the gate refuses is refused as the date header's" do
      plan = %{rows: "tr", fields: [field("t")], dateheader: header(selector: "b:nope(")}
      assert run(plan, dated()) == {:error, {:refused, :dateheader}}
    end
  end
end
