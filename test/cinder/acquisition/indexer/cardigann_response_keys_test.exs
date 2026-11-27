defmodule Cinder.Acquisition.Indexer.CardigannResponseKeysTest do
  # The search response keys of #1679 (`preprocessingfilters`, field `remove`, `rows.after`,
  # `dateheaders`, `rows.count` on HTML, selectors that read `.Result`), through the real
  # `Cinder.Acquisition.IndexerSource.Native` and parser worker, on Nyaa-shaped definitions and
  # pages written for Cinder (`Cinder.CardigannFixtures`), behind the `Cinder.CardigannStub` plug.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.Indexer.Cardigann.{Rows, Template}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp search_answer({:ok, rows, report}), do: {rows, outcomes(report)}
  defp search_answer({:error, {:no_indexer_answered, report}}), do: {[], outcomes(report)}

  defp frieren(n) do
    for i <- 1..n//1 do
      %{
        id: i,
        title: "[Group] Frieren - 0#{i} [1080p]",
        magnet: "magnet:?xt=urn:btih:#{String.duplicate(Integer.to_string(rem(i, 10)), 40)}",
        size: "1.4 GiB",
        date: "2026-11-25 10:30",
        cat: "1_2"
      }
    end
  end

  defp nyaa!(edit, secrets \\ %{}) do
    [indexer] = setup!([{"nyaa.yml", nyaa_like(edit)}], [{"nyaa.yml", nyaa_base(), secrets}])
    indexer
  end

  defp search, do: Native.search_tv_query("frieren", categories: [5070])

  defp preprocessing(definition, filters),
    do: put_in(definition, ["search", "preprocessingfilters"], filters)

  defp with_apikey(definition) do
    settings =
      definition["settings"] ++
        [%{"name" => "apikey", "type" => "password", "label" => "API key"}]

    Map.put(definition, "settings", settings)
  end

  describe "preprocessingfilters" do
    test "a re_replace that fixes the row markup turns a page with no rows into one with rows" do
      fix = [
        %{"name" => "re_replace", "args" => [~S|<tr class="brokn">|, ~S|<tr class="default">|]}
      ]

      broken = fn ->
        String.replace(nyaa_page(frieren(2)), ~s(<tr class="default">), ~s(<tr class="brokn">))
      end

      # The control: the same page without the filter has no row.
      nyaa!(& &1)
      route(%{"nyaa.test" => fn _conn, _query -> broken.() end})
      assert {:ok, [], _report} = search()

      Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
      indexer = nyaa!(&preprocessing(&1, fix))
      route(%{"nyaa.test" => fn _conn, _query -> broken.() end})

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}
      assert length(rows) == 2
    end

    test "a filter whose output passes the chain's cap fails the indexer with its tag and starts no backoff" do
      grow = [%{"name" => "re_replace", "args" => ["(.)", "$1$1$1$1$1$1$1$1$1$1"]}]
      indexer = nyaa!(&preprocessing(&1, grow))
      page = nyaa_page(frieren(20))
      # The page fits the cap, so only the filter's output passes it.
      assert byte_size(page) <= Template.output_cap()
      assert byte_size(page) * 10 > Template.output_cap()
      route(%{"nyaa.test" => fn _conn, _query -> page end})

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :filter_output_cap}}

      # Recorded as a partial page, as a field's limit is, not as a failure.
      status = IndexerStatus.read([indexer])[indexer.id]
      assert status.backoff == :none
      assert {status.last_partial, status.last_partial_at} == {:filter_output_cap, @now}
      assert status.last_failure == nil
    end

    # A regex filter's time grows with the square of the text's size, so a long page gets none.
    test "a page past the chain's cap is not filtered and reads as a partial page" do
      # The filter would strip the padding back under the cap, so only a page that never reaches
      # the filter reads as a partial page.
      strip = [%{"name" => "re_replace", "args" => ["~+", ""]}]
      indexer = nyaa!(&preprocessing(&1, strip))
      small = nyaa_page(frieren(2))
      refute small =~ "~"
      padded = small <> "<!-- " <> String.duplicate("~", Template.output_cap()) <> " -->"

      # The control: the page under the cap reads its rows through the same filter.
      route(%{"nyaa.test" => fn _conn, _query -> small end})
      assert {:ok, [_, _], _report} = search()

      Repo.delete_all(IndexerStatus)
      route(%{"nyaa.test" => fn _conn, _query -> padded end})
      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :filter_output_cap}}
    end

    test "a filter argument that names a secret setting drops the magnet rows, as a field's does" do
      names = fn template ->
        [%{"name" => "re_replace", "args" => ["zz-no-match", template]}]
      end

      for {template, kept} <- [
            {"{{ if .Config.apikey }}{{ else }}{{ end }}", 0},
            # The control: the same template on `.Keywords` keeps them.
            {"{{ if .Keywords }}{{ else }}{{ end }}", 2}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        nyaa!(&(&1 |> with_apikey() |> preprocessing(names.(template))), %{"apikey" => "k3y"})
        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(2)) end})

        assert {:ok, rows, _report} = search()
        assert length(rows) == kept
      end
    end
  end

  defp page(rows) do
    """
    <!doctype html><html><body><table class="torrent-list"><tbody>
    #{Enum.join(rows, "\n")}
    </tbody></table></body></html>
    """
  end

  # The first three cells of a Nyaa row: category, title, magnet.
  defp head_cells(i) do
    ~s(<td><a href="/?c=1_2">c</a></td><td><a href="/view/#{i}">[Group] Frieren - 0#{i} [1080p]</a></td>) <>
      ~s(<td><a href="magnet:?xt=urn:btih:#{String.duplicate("#{i}", 40)}">m</a></td>)
  end

  defp tail_cells(i), do: "<td>#{i}.0 GiB</td><td>2026-11-2#{i} 10:30</td><td>5</td>"

  describe "rows.after" do
    test "after: 1 reads four rows as two releases with the cells of both, five as three" do
      indexer = nyaa!(&put_in(&1, ["search", "rows", "after"], 1))

      four =
        for i <- 1..2,
            row <- [
              ~s(<tr class="default">#{head_cells(i)}</tr>),
              ~s(<tr class="default">#{tail_cells(i)}</tr>)
            ],
            do: row

      route(%{"nyaa.test" => fn _conn, _query -> page(four) end})

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}

      assert Enum.map(rows, &{&1.title, &1.size, &1.published_at}) == [
               {"[Group] Frieren - 01 [1080p]", 1_073_741_824, ~U[2026-11-21 10:30:00Z]},
               {"[Group] Frieren - 02 [1080p]", 2_147_483_648, ~U[2026-11-22 10:30:00Z]}
             ]

      # A fifth row starts a group the page ends inside: it reads alone, with no size or date.
      route(%{
        "nyaa.test" => fn _conn, _query ->
          page(four ++ [~s(<tr class="default">#{head_cells(3)}</tr>)])
        end
      })

      assert {:ok, rows, _report} = search()
      assert [_, _, %{title: "[Group] Frieren - 03 [1080p]", size: nil, published_at: nil}] = rows
    end
  end

  describe "dateheaders" do
    defp dated!(optional?, filters? \\ true) do
      # The filters of the Nyaa date field, as a v11 date header block runs `dateparse`.
      header = %{
        "selector" => "td[colspan] > b",
        "optional" => optional?,
        "filters" =>
          if(filters?,
            do: [
              %{"name" => "append", "args" => " -00:00"},
              %{"name" => "dateparse", "args" => "yyyy-MM-dd HH:mm zzz"}
            ],
            else: []
          )
      }

      nyaa!(&put_in(&1, ["search", "rows", "dateheaders"], header))
    end

    defp headed_page do
      page([
        ~s(<tr class="default">#{head_cells(1)}<td>1.0 GiB</td></tr>),
        ~s(<tr class="h"><td colspan="6"><b>2026-11-24 08:00</b></td></tr>),
        ~s(<tr class="default">#{head_cells(2)}<td>2.0 GiB</td></tr>),
        ~s(<tr class="default">#{head_cells(3)}<td>3.0 GiB</td><td>2026-11-25 10:30</td></tr>)
      ])
    end

    test "a row with no date takes its header row's, and a row before any header is dropped" do
      indexer = dated!(false)
      route(%{"nyaa.test" => fn _conn, _query -> headed_page() end})

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}

      # Row 1 has no header before it; row 3 keeps its own date.
      assert Enum.map(rows, &{&1.title, &1.published_at}) == [
               {"[Group] Frieren - 02 [1080p]", ~U[2026-11-24 08:00:00Z]},
               {"[Group] Frieren - 03 [1080p]", ~U[2026-11-25 10:30:00Z]}
             ]
    end

    test "with optional, the row before any header stays with no date" do
      dated!(true)
      route(%{"nyaa.test" => fn _conn, _query -> headed_page() end})

      assert {:ok, [first, _, _], _report} = search()
      assert {first.title, first.published_at} == {"[Group] Frieren - 01 [1080p]", nil}
    end

    test "a JSON page reads no date header, so its row with no date stays" do
      no_date = fn definition ->
        update_in(definition, ["search", "fields"], fn %{values: values} ->
          obj(List.keydelete(values, "date", 0))
        end)
      end

      rows = [
        %{id: 1, name: "Dune.2021.1080p.BluRay.x264-GRP1", size: 8_589_934_592, category: 1}
      ]

      [indexer] =
        setup!(
          [
            {"api.yml",
             api_like(fn definition ->
               definition
               |> no_date.()
               |> put_in(["search", "rows", "dateheaders"], %{"selector" => "h2"})
             end)}
          ],
          [{"api.yml", api_base(), %{"apikey" => "k3y-0f-the-t3st"}}]
        )

      route(%{"api.test" => fn _conn, _query -> {200, "application/json", api_page(rows)} end})

      assert {:ok, [row], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => :asked}
      assert {row.title, row.published_at} == {"Dune.2021.1080p.BluRay.x264-GRP1", nil}
    end

    test "a header whose text does not parse as a date drops the row, optional or not" do
      # No filters, so the text reaches `DotnetDate.from_unknown/2` as it is.
      for optional? <- [false, true] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        dated!(optional?, false)

        route(%{
          "nyaa.test" => fn _conn, _query ->
            page([
              ~s(<tr class="h"><td colspan="6"><b>not a date</b></td></tr>),
              ~s(<tr class="default">#{head_cells(2)}<td>2.0 GiB</td></tr>),
              ~s(<tr class="default">#{head_cells(3)}<td>3.0 GiB</td><td>2026-11-25 10:30</td></tr>)
            ])
          end
        })

        assert {:ok, [%{title: "[Group] Frieren - 03 [1080p]"}], _report} = search()
      end
    end
  end

  describe "rows.count" do
    # Prowlarr reads `rows.count` on a JSON page only, so an HTML page with one searches as it
    # would without it, even where its selector would read 0.
    test "an HTML page ignores it and keeps its rows" do
      count = %{
        "selector" => "tr.default",
        "filters" => [%{"name" => "re_replace", "args" => [".*", "0"]}]
      }

      indexer = nyaa!(&put_in(&1, ["search", "rows", "count"], count))
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(2)) end})

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}
      assert length(rows) == 2
    end
  end

  describe "field remove" do
    test "an HTML title cell reads without the removed tag's text" do
      remove = fn definition ->
        update_in(definition, ["search", "fields"], fn %{values: values} ->
          obj(
            List.keyreplace(values, "title_default", 0, {
              "title_default",
              %{"selector" => "td:nth-child(2) a:last-of-type", "remove" => "span.tag"}
            })
          )
        end)
      end

      tagged = fn ->
        String.replace(
          nyaa_page(frieren(1)),
          "[Group] Frieren - 01 [1080p]</a>",
          ~s([Group] Frieren - 01 [1080p]<span class="tag"> NEW</span></a>)
        )
      end

      for {edit, title} <- [
            {remove, "[Group] Frieren - 01 [1080p]"},
            # The control: without remove the tag's text stays.
            {& &1, "[Group] Frieren - 01 [1080p] NEW"}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        nyaa!(edit)
        route(%{"nyaa.test" => fn _conn, _query -> tagged.() end})

        assert {:ok, [row], _report} = search()
        assert row.title == title
      end
    end

    test "an XML title reads without the removed element's text" do
      for {remove, title} <- [{"tag", "Dune.2021.2160p-X1"}, {nil, "Dune.2021 NEW.2160p-X1"}] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)

        definition =
          rss_like(fn definition ->
            update_in(definition, ["search", "fields"], fn %{values: values} ->
              field =
                if remove,
                  do: %{"selector" => "title", "remove" => remove},
                  else: %{"selector" => "title"}

              obj(List.keyreplace(values, "title", 0, {"title", field}))
            end)
          end)

        setup!([{"rss.yml", definition}], [{"rss.yml", rss_base(), %{}}])
        item = %{title: "Dune.2021<tag> NEW</tag>.2160p-X1", id: 1, size: 4_000, category: 2000}

        route(%{
          "rss.test" => fn _conn, _query -> {200, "application/rss+xml", rss_page([item])} end
        })

        assert {:ok, [row], _report} = Native.search_movie_query("dune", [])
        assert row.title == title
      end
    end

    test "a field with remove and case stays not supported" do
      both = fn definition ->
        update_in(definition, ["search", "fields"], fn %{values: values} ->
          obj(
            values ++
              [{"free", %{"selector" => "td", "remove" => "i", "case" => obj([{"b", "1"}])}}]
          )
        end)
      end

      indexer = nyaa!(both)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(1)) end})

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:not_asked, {:not_supported, :selector_remove_case}}}
      assert requests() == []
    end
  end

  describe "the parser worker's input" do
    # docs/agents/architecture.md "The parser worker is not a security boundary": no secret goes
    # into the worker's input, unless the site's page already holds it.
    @secret "k3y-0f-the-t3st"

    defp secret_field(definition) do
      update_in(definition, ["search", "fields"], fn %{values: values} ->
        selector = "td[title='{{ .Config.apikey }}']"
        obj(values ++ [{"_probe", %{"selector" => selector, "optional" => true}}])
      end)
    end

    test "a preprocessing filter that writes a secret into the page fails the indexer" do
      write = fn template -> [%{"name" => "re_replace", "args" => ["</tbody>", template]}] end

      for {template, answer} <- [
            {"<!-- {{ .Config.apikey }} --></tbody>", :failed},
            # The control: the same filter writing the keywords.
            {"<!-- {{ .Keywords }} --></tbody>", :asked}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)

        indexer =
          nyaa!(&(&1 |> with_apikey() |> preprocessing(write.(template))), %{"apikey" => @secret})

        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(2)) end})

        case answer do
          :failed ->
            assert {[], outcomes} = search_answer(search())
            assert outcomes == %{indexer.id => {:failed, :definition_error}}

          :asked ->
            assert {:ok, [_, _], _report} = search()
        end
      end
    end

    test "a field selector that renders a secret fails the indexer, unless the page holds it" do
      indexer = nyaa!(&(&1 |> with_apikey() |> secret_field()), %{"apikey" => @secret})
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(2)) end})

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :definition_error}}

      Repo.delete_all(IndexerStatus)
      echoed = nyaa_page(frieren(2)) <> "<!-- #{@secret} -->"
      route(%{"nyaa.test" => fn _conn, _query -> echoed end})

      assert {:ok, [_, _], _report} = search()
    end

    test "a page that holds one secret does not let another into the input" do
      passkey = "pa55-w0rd-unr3lated"

      two_secrets = fn definition ->
        definition
        |> with_apikey()
        |> Map.update!("settings", &(&1 ++ [%{"name" => "passkey", "type" => "password"}]))
        |> secret_field()
      end

      indexer = nyaa!(two_secrets, %{"apikey" => @secret, "passkey" => passkey})
      # The page holds the passkey, as a tracker's download links do; the selector renders the
      # API key, which the page does not hold.
      paged = nyaa_page(frieren(2)) <> "<!-- #{passkey} -->"
      route(%{"nyaa.test" => fn _conn, _query -> paged end})

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :definition_error}}
    end
  end

  describe "selectors that read .Result" do
    # keepfriends' shape: a `_staff_edit` field, then a size whose column depends on it.
    defp staff_edit(definition) do
      update_in(definition, ["search", "fields"], fn %{values: values} ->
        {before, [{"size", _size} | rest]} = Enum.split_while(values, &(elem(&1, 0) != "size"))

        size =
          {"size",
           %{
             "selector" =>
               "{{ if .Result._staff_edit }}td:nth-child(5){{ else }}td:nth-child(4){{ end }}"
           }}

        obj(
          before ++
            [{"_staff_edit", %{"selector" => "a.staff", "optional" => true}}, size] ++ rest
        )
      end)
    end

    test "a row with the field set reads column 5, one without reads column 4" do
      indexer = nyaa!(&staff_edit/1)

      route(%{
        "nyaa.test" => fn _conn, _query ->
          page([
            ~s(<tr class="default">#{head_cells(1)}<td>1.0 GiB</td><td>2026-11-21 10:30</td></tr>),
            ~s(<tr class="default">#{head_cells(2)}<td><a class="staff">e</a></td><td>2.0 GiB</td><td>2026-11-22 10:30</td></tr>)
          ])
        end
      })

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}
      assert Enum.map(rows, & &1.size) == [1_073_741_824, 2_147_483_648]
    end

    # A size whose selector is the text the row's `_sel` cell holds.
    defp page_selected(definition) do
      update_in(definition, ["search", "fields"], fn %{values: values} ->
        {before, [{"size", _size} | rest]} = Enum.split_while(values, &(elem(&1, 0) != "size"))
        sel = {"_sel", %{"selector" => "td.sel"}}
        obj(before ++ [sel, {"size", %{"selector" => "{{ .Result._sel }}"}}] ++ rest)
      end)
    end

    defp selected_rows(selectors) do
      selectors
      |> Enum.with_index(1)
      |> Enum.map(fn {selector, i} ->
        hash = String.pad_leading(Integer.to_string(i), 40, "0")

        ~s(<tr class="default"><td><a href="/?c=1_2">c</a></td><td><a href="/view/#{i}">Frieren #{i}</a></td>) <>
          ~s(<td><a href="magnet:?xt=urn:btih:#{hash}">m</a></td><td class="sel">#{selector}</td>) <>
          ~s(<td class="s#{i}">#{i}.0 GiB</td></tr>)
      end)
      |> page()
    end

    test "a round selector that renders a secret fails the indexer" do
      # docs/agents/architecture.md "The parser worker is not a security boundary".
      secret_round = fn definition ->
        definition
        |> with_apikey()
        |> update_in(["search", "fields"], fn %{values: values} ->
          {before, [{"size", _size} | rest]} =
            Enum.split_while(values, &(elem(&1, 0) != "size"))

          size = {"size", %{"selector" => "tr[title='{{ .Config.apikey }}'] {{ .Result._sel }}"}}
          obj(before ++ [{"_sel", %{"selector" => "td.sel"}}, size] ++ rest)
        end)
      end

      indexer = nyaa!(secret_round, %{"apikey" => "k3y-0f-the-t3st"})
      route(%{"nyaa.test" => fn _conn, _query -> selected_rows(["td.s1", "td.s2"]) end})

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :definition_error}}
    end

    test "a rendering the gate refuses reads nil for its row only" do
      indexer = nyaa!(&page_selected/1)
      route(%{"nyaa.test" => fn _conn, _query -> selected_rows(["td.s1", "td[", "td.s3"]) end})

      assert {:ok, rows, report} = search()
      assert outcomes(report) == %{indexer.id => :asked}
      assert Enum.map(rows, & &1.size) == [1_073_741_824, nil, 3_221_225_472]
    end

    test "64 distinct renderings of one selector run, 65 fail the indexer" do
      cap = Rows.max_result_selectors()
      assert cap == 64
      indexer = nyaa!(&page_selected/1)

      route(%{
        "nyaa.test" => fn _conn, _query -> selected_rows(for i <- 1..cap, do: "td.s#{i}") end
      })

      assert {:ok, rows, _report} = search()
      assert length(rows) == cap

      route(%{
        "nyaa.test" => fn _conn, _query ->
          selected_rows(for i <- 1..(cap + 1), do: "td.s#{i}")
        end
      })

      assert {[], outcomes} = search_answer(search())
      assert outcomes == %{indexer.id => {:failed, :definition_error}}
    end
  end
end
