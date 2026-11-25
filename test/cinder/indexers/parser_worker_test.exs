defmodule Cinder.Indexers.ParserWorkerTest do
  # Every test here starts the real worker: an `erl` from this system's ERTS running
  # `ParserWorker.child/0` with lazy_html. `ParserWorkerBoundsTest` swaps the command for stubs.
  use ExUnit.Case, async: true

  alias Cinder.Indexers.ParserWorker

  @deadline 30_000

  @page """
  <html><body><table>
  <tr class="row" data-id="1"><td class="name"><a href="/one" title="One">One <i>(new)</i> film</a></td><td>1.5 GB</td></tr>
  <tr class="row" data-id="2"><td class="name"><a href="/two">Two</a></td><td>700 MB</td><td><b>free</b></td></tr>
  </table></body></html>
  """

  defp field(name, attrs \\ []) do
    Map.merge(%{name: name, selector: nil, attribute: nil, remove: [], case: []}, Map.new(attrs))
  end

  defp run(plan, html \\ @page), do: ParserWorker.run(html, plan, deadline_ms: @deadline)

  test "the limits the app runs with" do
    assert ParserWorker.max_output_bytes() == 4_194_304
    assert ParserWorker.max_memory_bytes() == 536_870_912
    assert ParserWorker.memory_poll_ms() == 50
    assert ParserWorker.address_space_kib() == 4_194_304
    assert ParserWorker.check_deadline_ms() == 30_000
    assert ParserWorker.max_check_workers() == 2
  end

  test "the worker starts from erts-<version>/bin/erl under this system's root" do
    root = List.to_string(:code.root_dir())
    version = List.to_string(:erlang.system_info(:version))

    assert ParserWorker.erl_path() == root <> "/erts-" <> version <> "/bin/erl"
    assert File.regular?(ParserWorker.erl_path())
  end

  test "lazy_html is a runtime dependency of cinder, so the release holds it" do
    assert :lazy_html in Application.spec(:cinder, :applications)
  end

  test "td b on a small document answers its row" do
    html = "<table><tr><td><b>x</b></td></tr></table>"

    assert run(%{rows: "td b", fields: [field("text")]}, html) == {:ok, [[{"text", "x"}]]}
  end

  test "a row selector with an attribute field and a text field with remove answers both in plan " <>
         "order" do
    plan = %{
      rows: "tr.row",
      fields: [
        field("title", selector: "td.name a", remove: ["i"]),
        field("link", selector: "a", attribute: "href")
      ]
    }

    assert run(plan) ==
             {:ok,
              [
                [{"title", "One  film"}, {"link", "/one"}],
                [{"title", "Two"}, {"link", "/two"}]
              ]}
  end

  test "remove takes out only descendants, never the element itself" do
    plan = %{rows: "tr.row", fields: [field("name", selector: "a", remove: ["a", "i"])]}

    assert run(plan) == {:ok, [[{"name", "One  film"}], [{"name", "Two"}]]}
  end

  test "a field selector that matches the row reads the row, else its first descendant" do
    plan = %{
      rows: "tr.row",
      fields: [
        field("own", selector: "tr", attribute: "data-id"),
        field("cell", selector: "td", attribute: "class"),
        field("none", selector: "span")
      ]
    }

    assert run(plan) ==
             {:ok,
              [
                [{"own", "1"}, {"cell", "name"}, {"none", nil}],
                [{"own", "2"}, {"cell", "name"}, {"none", nil}]
              ]}
  end

  test "a missing attribute reads nil, and a field with no selector reads the row's text" do
    plan = %{
      rows: "tr.row",
      fields: [field("title", selector: "a", attribute: "title"), field("all")]
    }

    assert run(plan) ==
             {:ok,
              [
                [{"title", "One"}, {"all", "One (new) film1.5 GB"}],
                [{"title", nil}, {"all", "Two700 MBfree"}]
              ]}
  end

  test "a case block reports the first of its selectors that matches" do
    plan = %{rows: "tr.row", fields: [field("free", case: ["b", "td", "span"])]}

    assert run(plan) == {:ok, [[{"free", {:case, "td"}}], [{"free", {:case, "b"}}]]}

    plan = %{rows: "tr.row", fields: [field("free", case: ["span"])]}
    assert run(plan) == {:ok, [[{"free", nil}], [{"free", nil}]]}
  end

  test "td:contains(\"x\") answers the cells whose text holds it, case-sensitive, through " <>
         "descendants" do
    html = """
    <table><tr>
    <td id="a">x</td><td id="b"><b>a<i>x</i></b></td><td id="c">X</td><td id="d">y</td>
    </tr></table>
    """

    plan = %{rows: ~S|td:contains("x")|, fields: [field("id", attribute: "id")]}
    assert run(plan, html) == {:ok, [[{"id", "a"}], [{"id", "b"}]]}
  end

  test "a page that already carries attributes named like the marker does not match" do
    html = """
    <table><tr>
    <td id="planted" cinder-r-c0 cinder-00000000000000000000000000000000-r-c0
      cinder-ffffffffffffffffffffffffffffffff-r-c0>y</td>
    <td id="real">x</td>
    </tr></table>
    """

    plan = %{rows: ~S|td:contains("x")|, fields: [field("id", attribute: "id")]}
    assert run(plan, html) == {:ok, [[{"id", "real"}]]}
  end

  test "td:has(b[border=1]) ends the worker as :crash, and this VM runs the next query" do
    html = "<table><tr><td><b>x</b></td></tr></table>"

    assert run(%{rows: "td:has(b[border=1])", fields: []}, html) == {:error, :crash}
    assert run(%{rows: "td b", fields: []}, html) == {:ok, [[]]}
  end

  test "a selector lexbor refuses answers where it sits" do
    assert run(%{rows: "td[border=1]", fields: []}) == {:error, {:refused, :rows}}

    plan = %{rows: "tr", fields: [field("a", selector: "a"), field("b", selector: ~S|[id!="x"]|)]}
    assert run(plan) == {:error, {:refused, {:field, 1}}}

    plan = %{rows: "tr", fields: [field("a", selector: "a", remove: ["b["])]}
    assert run(plan) == {:error, {:refused, {:field, 0}}}

    plan = %{rows: "tr", fields: [field("a", case: ["b", "td:foo"])]}
    assert run(plan) == {:error, {:refused, {:field, 0}}}
  end

  test "a selector the gate refuses answers where it sits without a worker" do
    assert run(%{rows: "tr /* x */", fields: []}) == {:error, {:refused, :rows}}

    plan = %{rows: "tr", fields: [field("a", selector: ~S|a[href=\"x\"]|)]}
    assert run(plan) == {:error, {:refused, {:field, 0}}}
  end

  test "an answer past the output cap reads :output_too_large" do
    plan = %{rows: "tr.row", fields: [field("all")]}

    assert ParserWorker.run(@page, plan, deadline_ms: @deadline, max_output_bytes: 20) ==
             {:error, :output_too_large}
  end

  test "an answer of exactly the output cap passes" do
    plan = %{rows: "td b", fields: [field("t")]}
    html = "<table><tr><td><b>x</b></td></tr></table>"
    # 4-byte frame length, then ?R, 2 x 4-byte counts, then <<1, 1::32, "x">>.
    size = 4 + 1 + 8 + 6

    assert ParserWorker.run(html, plan, deadline_ms: @deadline, max_output_bytes: size) ==
             {:ok, [[{"t", "x"}]]}

    assert ParserWorker.run(html, plan, deadline_ms: @deadline, max_output_bytes: size - 1) ==
             {:error, :output_too_large}
  end

  test "a worker past the memory cap reads :memory" do
    assert ParserWorker.run(@page, %{rows: "tr", fields: []},
             deadline_ms: @deadline,
             max_memory_bytes: 1_000_000
           ) == {:error, :memory}
  end

  describe "check_selectors/2" do
    test "answers each selector: ok, the gate's refusal, or refused by lexbor" do
      assert ParserWorker.check_selectors([
               "td b",
               ~S|[id!="x"]|,
               "td /* x */",
               ~S|img[src$=\"x\"]|,
               "td:has()",
               ~S|a[href*="{{ .Config.x }}"]|,
               ~S|td:has(> b:contains("x"))|
             ]) ==
               {:ok,
                [
                  {"td b", :ok},
                  {~S|[id!="x"]|, :refused},
                  {"td /* x */", :comment},
                  {~S|img[src$=\"x\"]|, :escape},
                  {"td:has()", :structure},
                  {~S|a[href*="{{ .Config.x }}"]|, :template},
                  {~S|td:has(> b:contains("x"))|, :ok}
                ]}
    end

    test "runs each part alone before the whole, so td:has(b[border=1]) is refused, not a crash" do
      assert ParserWorker.check_selectors(["td:has(b[border=1])", "td b"]) ==
               {:ok, [{"td:has(b[border=1])", :refused}, {"td b", :ok}]}
    end

    test "a skeleton lexbor refuses is refused before the arguments run" do
      assert ParserWorker.check_selectors(["td:nth-child(x):has(b)"]) ==
               {:ok, [{"td:nth-child(x):has(b)", :refused}]}
    end

    test "only gate refusals start no worker" do
      assert ParserWorker.check_selectors(["a /* x */"], max_memory_bytes: 1) ==
               {:ok, [{"a /* x */", :comment}]}
    end
  end
end
