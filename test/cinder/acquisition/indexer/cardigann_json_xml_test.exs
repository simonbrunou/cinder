defmodule Cinder.Acquisition.Indexer.CardigannJsonXmlTest do
  # #1678: the Cardigann adapter on definitions that answer JSON or XML, in a non-UTF-8 encoding,
  # through the real `Cinder.Acquisition.IndexerSource.Native`, on definitions and answers
  # written for Cinder (`Cinder.CardigannFixtures`), behind the `Cinder.CardigannStub` plug.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase

  @now ~U[2026-11-26 12:00:00Z]
  # A filter that hits `BoundedRegex`'s match limit on `@backtracks`, and on no other title.
  @limit_filter %{"name" => "re_replace", "args" => ["^(a+)+$", "x"]}
  @backtracks String.duplicate("a", 30) <> "!"
  @key "k3y-0f-the-t3st"

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp search_answer({:ok, rows, report}), do: {rows, outcomes(report)}
  defp search_answer({:error, {:no_indexer_answered, report}}), do: {[], outcomes(report)}

  defp api!(edit \\ & &1) do
    [indexer] =
      setup!([{"api.yml", api_like(edit)}], [{"api.yml", api_base(), %{"apikey" => @key}}])

    indexer
  end

  defp rss!(edit \\ & &1) do
    [indexer] = setup!([{"rss.yml", rss_like(edit)}], [{"rss.yml", rss_base(), %{}}])
    indexer
  end

  defp json(body), do: {200, "application/json", body}
  defp xml(body), do: {200, "application/rss+xml", body}

  defp dune(n \\ 1) do
    for i <- 1..n//1 do
      %{id: i, name: "Dune.2021.1080p.BluRay.x264-GRP#{i}", size: 8_589_934_592, category: 1}
    end
  end

  # The fields with `name` read first and a `title` built last from `template`, so a test can
  # read the other fields' values in the row's title.
  defp titled(definition, template, selector \\ "name") do
    update_in(definition, ["search", "fields"], fn %{values: values} ->
      kept = List.keydelete(values, "title", 0)
      obj([{"name", %{"selector" => selector}} | kept] ++ [{"title", %{"text" => template}}])
    end)
  end

  defp put_field(definition, name, field) do
    update_in(definition, ["search", "fields"], fn %{values: values} ->
      obj(List.keystore(values, name, 0, {name, field}))
    end)
  end

  defp put_response(definition, response) do
    update_in(definition, ["search", "paths"], fn [path] ->
      [Map.put(path, "response", response)]
    end)
  end

  defp put_rows(definition, key, value), do: put_in(definition, ["search", "rows", key], value)

  defp titles(rows), do: Enum.map(rows, & &1.title)

  describe "a JSON API definition" do
    test "a search reads each row's fields and drops the hidden row" do
      indexer = api!()
      [shown] = dune()
      hidden = %{id: 9, name: "Dune.2021.720p.WEB-HID", size: 1_000, category: 1, hidden: true}
      route(%{"api.test" => fn _conn, _query -> json(api_page([shown, hidden])) end})

      assert {:ok, [row], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => :asked}

      assert [{"api.test", "/api/torrents/filter", %{"api_token" => @key, "name" => "dune"}}] =
               requests()

      assert row.title == shown.name
      assert row.download_url == "https://api.test/torrent/download/1.abc"
      assert row.size == 8_589_934_592
      assert row.category_ids == [2000]
      assert row.published_at == ~U[2026-11-25 10:30:00Z]
    end

    test "an array field joins its items, a case reads True and False, and ..id reads the row before attribute" do
      api!(
        &titled(
          &1,
          "{{ .Result.name }} [{{ .Result.genres }}] f{{ .Result.free }} i{{ .Result.id }}"
        )
      )

      [free, paid] = dune(2)
      free = Map.merge(free, %{genres: ["Sci-Fi", 2, true], freeleech: true, id: 41})
      paid = Map.merge(paid, %{genres: [], freeleech: false, id: 42})
      route(%{"api.test" => fn _conn, _query -> json(api_page([free, paid])) end})

      assert {:ok, rows, _report} = Native.search_movie_query("dune", [])
      assert titles(rows) == ["#{free.name} [Sci-Fi,2,True] f1 i41", "#{paid.name} [] f0 i42"]
    end

    test "the rows selector is a template, rendered with the search's variables" do
      # No noResultsMessage: the answer below holds an empty `data` list.
      indexer =
        api!(fn definition ->
          definition
          |> put_response(%{"type" => "json"})
          |> put_rows("selector", "{{ if .Keywords }}data{{ else }}latest{{ end }}")
        end)

      latest = Jason.decode!(api_page(dune()), objects: :ordered_objects)["data"]
      page = Jason.encode!(obj([{"data", []}, {"latest", latest}]))
      route(%{"api.test" => fn _conn, _query -> json(page) end})

      # A search has keywords, so it reads `data`; the keywordless Test reads `latest`.
      assert {:ok, [], _report} = Native.search_movie_query("dune", [])
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
    end

    test "a rows selector keeps the rows its :has, :not and :contains filters pass" do
      # A plain key tests that the key is there, a filtered key that its value passes the filter.
      # `:contains` tests the text as written, quotes included, as Prowlarr's `Contains(key)`
      # does: a quoted text finds a whole string value in the row's JSON text.
      cases = [
        {"data:has(attributes.hidden)", ["C"]},
        {"data:has(attributes.name:contains(2160p))", ["A"]},
        {"data:not(attributes.hidden)", ["A", "B"]},
        {"data:not(attributes.name:contains(CAM))", ["A", "C"]},
        {"data:contains(CAM)", ["B"]},
        {~S|data:contains("CAM")|, []},
        {~S|data:contains("Dune.2021.CAM-B")|, ["B"]},
        {"data:not(attributes.hidden):contains(Dune)", ["A", "B"]}
      ]

      files =
        for {{selector, _expected}, n} <- Enum.with_index(cases) do
          {"api#{n}.yml", api_like(&put_rows(&1, "selector", selector))}
        end

      indexers =
        setup!(files, for({name, _} <- files, do: {name, api_base(), %{"apikey" => @key}}))

      rows = [
        %{id: 1, name: "Dune.2021.2160p.WEB-A", size: 1, category: 1},
        %{id: 2, name: "Dune.2021.CAM-B", size: 1, category: 1},
        %{id: 3, name: "Dune.2021.1080p.BluRay-C", size: 1, category: 1, hidden: true}
      ]

      route(%{"api.test" => fn _conn, _query -> json(api_page(rows)) end})
      assert {:ok, found, _report} = Native.search_movie_query("dune", [])

      for {{selector, expected}, indexer} <- Enum.zip(cases, indexers) do
        kept = for row <- found, row.indexer_id == indexer.id, do: String.last(row.title)
        assert {selector, kept} == {selector, expected}
      end
    end

    test "a case reads * for a JSON null, and a missing or refused value skips the case" do
      star = %{
        "selector" => "promo",
        "optional" => "true",
        "case" => obj([{"x", "1"}, {"*", "star"}])
      }

      api!(fn definition ->
        definition
        |> put_field("promo", star)
        |> titled("{{ .Result.name }} p{{ .Result.promo }}")
      end)

      page =
        Jason.encode!(
          obj([
            {"data",
             for {promo, i} <- Enum.with_index([nil, :missing, obj([{"k", 1}]), "x", "y"], 1) do
               attributes =
                 [{"name", "Dune.2021.1080p-P#{i}"}, {"download_link", "https://api.test/d/#{i}"}] ++
                   if(promo == :missing, do: [], else: [{"promo", promo}])

               obj([{"id", i}, {"attributes", obj(attributes)}])
             end}
          ])
        )

      route(%{"api.test" => fn _conn, _query -> json(page) end})

      assert {:ok, rows, _report} = Native.search_movie_query("dune", [])

      assert titles(rows) == [
               "Dune.2021.1080p-P1 pstar",
               "Dune.2021.1080p-P2 p",
               "Dune.2021.1080p-P3 p",
               "Dune.2021.1080p-P4 p1",
               "Dune.2021.1080p-P5 pstar"
             ]
    end

    test "rows.multiple makes a row of each object of the attribute's array" do
      api!(fn definition ->
        definition
        |> put_rows("selector", "groups")
        |> put_rows("attribute", "torrents")
        |> put_rows("multiple", true)
        |> put_in(
          ["search", "rows"],
          definition["search"]["rows"]
          |> Map.delete("count")
          |> Map.merge(%{"selector" => "groups", "attribute" => "torrents", "multiple" => true})
        )
      end)

      torrent = fn i ->
        obj([{"name", "Dune.2021.1080p-M#{i}"}, {"download_link", "https://api.test/d/#{i}"}])
      end

      page =
        Jason.encode!(
          obj([
            {"groups",
             [
               obj([{"torrents", [torrent.(1), 5, torrent.(2)]}]),
               # No `torrents`: the group's own name and link must not make a row.
               obj([{"name", "Dune.2021.1080p-GROUP"}, {"download_link", "https://api.test/g"}]),
               obj([{"torrents", [torrent.(3)]}])
             ]}
          ])
        )

      route(%{"api.test" => fn _conn, _query -> json(page) end})
      assert {:ok, rows, _report} = Native.search_movie_query("dune", [])
      assert titles(rows) == ["Dune.2021.1080p-M1", "Dune.2021.1080p-M2", "Dune.2021.1080p-M3"]
    end

    test "noResultsMessage gives no rows when the body holds it, and a blank one on a blank body" do
      indexer = api!()
      route(%{"api.test" => fn _conn, _query -> json(~S({"data":[], "meta": {"total": 0}})) end})
      assert {:ok, [], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => :asked}

      # The message is a plain substring: a body that holds it gives no rows, though it has one.
      page = api_page(dune()) <> ~S( "data":[])
      route(%{"api.test" => fn _conn, _query -> json(page) end})
      assert {:ok, [], _report} = Native.search_movie_query("dune", [])

      Repo.delete_all(IndexerStatus)
      blank = api!(&put_response(&1, %{"type" => "json", "noResultsMessage" => ""}))
      route(%{"api.test" => fn _conn, _query -> json(" ") end})
      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes[blank.id] == :asked

      # A blank message matches only a blank body: a body with a row reads that row.
      route(%{"api.test" => fn _conn, _query -> json(api_page(dune())) end})
      assert {:ok, rows, _report} = Native.search_movie_query("dune", [])
      assert [_row] = Enum.filter(rows, &(&1.indexer_id == blank.id))
    end

    test "a rows.count below 1 gives no rows, and one that does not read as a number changes nothing" do
      api!()
      route(%{"api.test" => fn _conn, _query -> json(api_page(dune(2), total: 0)) end})
      assert {:ok, [], _report} = Native.search_movie_query("dune", [])

      route(%{"api.test" => fn _conn, _query -> json(api_page(dune(2), total: "many")) end})
      assert {:ok, [_, _], _report} = Native.search_movie_query("dune", [])

      route(%{
        "api.test" => fn _conn, _query -> json(api_page(dune(2), total: 3_000_000_000)) end
      })

      assert {:ok, [_, _], _report} = Native.search_movie_query("dune", [])
    end

    test "a body that is not JSON, or with no rows list, fails the indexer" do
      indexer = api!()

      for {body, failure} <- [
            {"<html>maintenance</html>", :invalid_json},
            {~S({"data": [1,]}), :invalid_json},
            {~S({"error": "token expired"}), :no_results_list},
            {~S({"data": {"id": 1}}), :no_results_list}
          ] do
        Repo.delete_all(IndexerStatus)
        route(%{"api.test" => fn _conn, _query -> json(body) end})
        assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
        assert {body, outcomes[indexer.id]} == {body, {:failed, failure}}
      end
    end

    test "a body nesting a 65th object or array fails the indexer; 64 levels read" do
      indexer = api!()
      arrays = fn d -> String.duplicate("[", d) <> String.duplicate("]", d) end

      # The body, `data`, the row and its `attributes` are four levels; `deep` adds the rest.
      page = fn deep ->
        ~s({"data":[{"id":1,"attributes":{"name":"Dune.2021.1080p-D",) <>
          ~s("download_link":"https://api.test/d/1","deep":#{arrays.(deep)}}}]})
      end

      route(%{"api.test" => fn _conn, _query -> json(page.(60)) end})
      assert {[row], _outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert row.title == "Dune.2021.1080p-D"

      Repo.delete_all(IndexerStatus)
      route(%{"api.test" => fn _conn, _query -> json(page.(61)) end})
      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes[indexer.id] == {:failed, :invalid_json}
    end

    test "with missingAttributeEqualsNoResults a missing rows list gives no rows" do
      indexer = api!(&put_rows(&1, "missingAttributeEqualsNoResults", true))
      route(%{"api.test" => fn _conn, _query -> json(~S({"error": "nothing"})) end})
      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes[indexer.id] == :asked
    end

    test "the Test passes on a JSON page with a row and reads no rows on an empty one" do
      indexer = api!()
      route(%{"api.test" => fn _conn, _query -> json(api_page(dune())) end})
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)

      route(%{"api.test" => fn _conn, _query -> json(api_page([])) end})
      assert {:ok, %{outcome: :no_rows}} = Native.test_indexer(indexer.id)

      route(%{"api.test" => fn _conn, _query -> json("not json") end})
      assert {:ok, %{outcome: outcome}} = Native.test_indexer(indexer.id)
      assert outcome == :invalid_json
    end

    test "a limit or a transport failure never carries the API key the stub saw" do
      indexer = api!()

      for {answer, outcome} <- [
            {{429, "application/json", ~s({"message": "slow down, #{@key}"})},
             &match?({:failed, {:limit, %DateTime{}}}, &1)},
            {{:transport, :econnrefused}, &(&1 == {:failed, :connection_refused})}
          ] do
        Repo.delete_all(IndexerStatus)
        route(%{"api.test" => fn _conn, _query -> answer end})

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:answer, Native.search_movie_query("dune", [])})
          end)

        assert_received {:answer, answer}
        assert {[], outcomes} = search_answer(answer)
        assert outcome.(outcomes[indexer.id])
        assert [{"api.test", _path, %{"api_token" => @key}}] = requests()
        refute inspect(answer) =~ "k3y-0f"
        refute log =~ "k3y-0f"
      end
    end

    test "a JSON body of the 2 MiB cap is read and one byte more fails" do
      indexer = api!()
      page = api_page(dune())

      padded = fn size ->
        String.replace_suffix(
          page,
          "}",
          ~s(, "pad": ") <> String.duplicate("x", size - byte_size(page) - 11) <> ~s("})
        )
      end

      assert byte_size(padded.(2_097_152)) == 2_097_152

      route(%{"api.test" => fn _conn, _query -> json(padded.(2_097_152)) end})
      assert {:ok, [_row], _report} = Native.search_movie_query("dune", [])

      Repo.delete_all(IndexerStatus)
      route(%{"api.test" => fn _conn, _query -> json(padded.(2_097_153)) end})
      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :too_large}}
    end

    test "one page reads 1,000 rows: a 1,001st row whose title would hit the regex limit is never read" do
      indexer =
        api!(&put_field(&1, "title", %{"selector" => "name", "filters" => [@limit_filter]}))

      last = %{id: 1_001, name: @backtracks, size: 1, category: 1}
      route(%{"api.test" => fn _conn, _query -> json(api_page(dune(1_000) ++ [last])) end})

      assert {kept, outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert length(kept) == 1_000
      assert List.last(kept).download_url == "https://api.test/torrent/download/1000.abc"
      assert outcomes == %{indexer.id => :asked}

      # The positive control: the same row within the first 1,000 hits the limit.
      route(%{"api.test" => fn _conn, _query -> json(api_page([last | dune(999)])) end})
      assert {_kept, outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :regex_limit}}
    end
  end

  defp items(n),
    do:
      for(i <- 1..n//1, do: %{title: "Dune.2021.2160p-X#{i}", id: i, size: 4_000, category: 2000})

  describe "an XML feed definition" do
    test "a search reads each item's fields: elements, attributes, a namespaced element, :contains" do
      indexer = rss!()
      [plain, free] = items(2)
      free = Map.merge(free, %{description: "Freeleech for 48h", seeders: 12})
      route(%{"rss.test" => fn _conn, _query -> xml(rss_page([plain, free])) end})

      assert {:ok, [first, second], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => :asked}
      assert [{"rss.test", "/rss", %{"q" => "dune"}}] = requests()

      assert first.title == plain.title
      assert first.download_url == "https://rss.test/download/1.torrent"
      assert first.size == 4_000
      assert first.category_ids == [2000]
      assert first.published_at == ~U[2026-11-25 10:30:00Z]
      assert second.download_url == "https://rss.test/download/2.torrent"
    end

    test "a field reads its selector's first match, a case its :contains key" do
      rss!(&titled(&1, "{{ .Result.name }} s{{ .Result.seeders }} f{{ .Result.free }}", "title"))
      [plain, free] = items(2)
      free = Map.merge(free, %{description: "Freeleech for 48h", seeders: 12})
      route(%{"rss.test" => fn _conn, _query -> xml(rss_page([plain, free])) end})

      assert {:ok, rows, _report} =
               Native.search_movie_query("dune", [])

      assert titles(rows) == ["#{plain.title} s4 f0", "#{free.title} s12 f1"]
    end

    test "an attribute the element lacks reads nothing: no download link, no size" do
      rss!()
      [kept, unlinked, unsized] = items(3)
      unsized = %{unsized | size: 4_001}

      page =
        [kept, unlinked, unsized]
        |> rss_page()
        |> String.replace(~s(url="#{rss_base()}download/#{unlinked.id}.torrent" ), "")
        |> String.replace(~s(length="#{unsized.size}" ), "")

      route(%{"rss.test" => fn _conn, _query -> xml(page) end})
      assert {:ok, rows, _report} = Native.search_movie_query("dune", [])

      # The item with no enclosure url has no download link, so the row drops.
      assert titles(rows) == [kept.title, unsized.title]
      assert Enum.map(rows, & &1.size) == [kept.size, nil]
    end

    test "a page with a DTD or an entity declaration fails, its entities never expanded" do
      indexer = rss!()

      for extra <- [
            ~s(<!DOCTYPE rss [<!ENTITY big "#{String.duplicate("x", 50)}">]>\n),
            ~s(<!DOCTYPE rss SYSTEM "https://rss.test/rss.dtd">\n),
            ~s(<!ENTITY big "x">\n)
          ] do
        Repo.delete_all(IndexerStatus)
        route(%{"rss.test" => fn _conn, _query -> xml(rss_page(items(1), extra: extra)) end})
        assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
        assert outcomes[indexer.id] == {:failed, :xml_dtd}
      end
    end

    test "an undeclared entity stays as written" do
      rss!()
      [item] = items(1)

      route(%{
        "rss.test" => fn _conn, _query -> xml(rss_page([%{item | title: "Dune &big; 2021"}])) end
      })

      assert {:ok, [row], _report} = Native.search_movie_query("dune", [])
      assert row.title == "Dune &big; 2021"
    end

    test "a page that is not XML fails the indexer" do
      indexer = rss!()

      for body <- ["<rss><channel><item></channel></rss>", "not xml at all", ""] do
        Repo.delete_all(IndexerStatus)
        route(%{"rss.test" => fn _conn, _query -> xml(body) end})
        assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
        assert {body, outcomes[indexer.id]} == {body, {:failed, :invalid_xml}}
      end
    end

    test "a windows-1251 page whose declaration names its encoding reads in that charset" do
      rss!(&Map.put(&1, "encoding", "windows-1251"))
      [item] = items(1)
      prolog = ~s(<?xml version="1.0" encoding="windows-1251"?>\n)
      page = rss_page([%{item | title: "WORD 2021 1080p"}], prolog: prolog)
      # "Дюна" written in windows-1251 by hand.
      bytes = String.replace(page, "WORD", <<0xC4, 0xFE, 0xED, 0xE0>>)
      route(%{"rss.test" => fn _conn, _query -> {200, "application/xml", bytes} end})

      assert {:ok, [row], _report} = Native.search_movie_query("dune", [])
      assert row.title == "Дюна 2021 1080p"
    end

    test "a type selector reads an element's local name, its prefix dropped" do
      rss!(fn definition ->
        definition
        |> put_field("seeders", %{"selector" => "attr[name=seeders]", "attribute" => "value"})
        |> titled("{{ .Result.name }} s{{ .Result.seeders }}", "title")
      end)

      route(%{"rss.test" => fn _conn, _query -> xml(rss_page(items(1))) end})
      assert {:ok, [row], _report} = Native.search_movie_query("dune", [])
      assert row.title == "Dune.2021.2160p-X1 s4"
    end

    test "one page reads 1,000 items and an XML body of one byte over the cap fails" do
      indexer =
        rss!(&put_field(&1, "title", %{"selector" => "title", "filters" => [@limit_filter]}))

      last = %{hd(items(1)) | title: @backtracks, id: 1_001}
      route(%{"rss.test" => fn _conn, _query -> xml(rss_page(items(1_000) ++ [last])) end})
      # A 1,001st item whose title would hit the regex limit is never read.
      assert {kept, outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert length(kept) == 1_000
      assert outcomes == %{indexer.id => :asked}

      # The positive control: the same item within the first 1,000 hits the limit.
      Repo.delete_all(IndexerStatus)
      route(%{"rss.test" => fn _conn, _query -> xml(rss_page([last | items(999)])) end})
      assert {_kept, outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :regex_limit}}

      page = rss_page(items(1))
      over = page <> "<!--" <> String.duplicate("x", 2_097_153 - byte_size(page) - 7) <> "-->"
      Repo.delete_all(IndexerStatus)
      route(%{"rss.test" => fn _conn, _query -> xml(over) end})
      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :too_large}}
    end
  end

  describe "a definition with pinned certificates" do
    # The TLS rule itself runs on a real HTTPS server in `Cinder.HTTPPolicy.PinnedAdapterTest`;
    # the search and the grab both build their requests through `Cardigann.copy/1`.
    test "a copy's request holds the pins for its stored base URL's host" do
      hex = "0123456789ABCDEF0123456789abcdef01234567"

      definition =
        nyaa_like(fn definition ->
          definition
          |> Map.put("links", [nyaa_base(), "https://Mirror.test/"])
          |> Map.put("certificates", [hex])
        end)

      [indexer] =
        setup!([{"nyaa.yml", definition}], [{"nyaa.yml", "https://Mirror.test/", %{}}])

      assert {:ok, copy} = Cardigann.copy(indexer)
      request = copy.request.(%{deadline_at: 0}, @now)
      assert request.certificate_pins == {"Mirror.test", [Base.decode16!(hex, case: :mixed)]}
    end
  end

  describe "a definition in windows-1251" do
    # Req.Test's plug step refuses a query string that is not UTF-8 before the stub runs, so the
    # keywords' bytes are `Cinder.Acquisition.Indexer.Cardigann.QueryTest`'s.
    test "its page reads in windows-1251 over a Content-Type that names UTF-8" do
      definition =
        nyaa_like(fn definition ->
          definition
          |> Map.put("encoding", "windows-1251")
          |> update_in(["search", "fields", "title"], fn title ->
            Map.update(
              title,
              "filters",
              [%{"name" => "urldecode"}],
              &(&1 ++ [%{"name" => "urldecode"}])
            )
          end)
        end)

      [_indexer] = setup!([{"nyaa.yml", definition}], [{"nyaa.yml", nyaa_base(), %{}}])

      page =
        nyaa_page([
          %{
            # urldecode reads "%C4%FE%ED%E0" in windows-1251.
            title: "[Group] WORD - 01 [1080p] %C4%FE%ED%E0",
            magnet: "magnet:?xt=urn:btih:" <> String.duplicate("1", 40),
            size: "1.4 GiB",
            date: "2026-11-25 10:30",
            cat: "1_2"
          }
        ])

      # "Фрирен" written in windows-1251 by hand.
      bytes = String.replace(page, "WORD", <<0xD4, 0xF0, 0xE8, 0xF0, 0xE5, 0xED>>)
      route(%{"nyaa.test" => fn _conn, _query -> {200, "text/html; charset=utf-8", bytes} end})

      assert {:ok, [row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert row.title == "[Group] Фрирен - 01 [1080p] Дюна"
    end

    @passkey "Пароль-ключ"

    # No template reads the passkey: the keywords carry it into the query, so only the value
    # check sees it. A host the keywords fill is no credential host, since the definition cannot
    # name it; here their ASCII letters alone.
    defp secret_search!(host, keywords) do
      unread = fn definition ->
        definition
        |> Map.put("encoding", "windows-1251")
        |> Map.update!(
          "settings",
          &(&1 ++ [%{"name" => "passkey", "type" => "password", "label" => "Passkey"}])
        )
        |> put_in(["search", "paths"], [
          %{"path" => host, "inputs" => obj([{"q", "{{ .Keywords }}"}])}
        ])
      end

      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(unread)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => @passkey}}
        ])

      route(%{
        "frieren.mirror.test" => fn _conn, _query -> nyaa_page([]) end,
        "nyaa.test" => fn _conn, _query -> nyaa_page([]) end
      })

      {_rows, outcomes} = search_answer(Native.search_tv_query(keywords, categories: [5070]))
      {Map.fetch!(outcomes, indexer.id), requests()}
    end

    @mirror ~S(https://{{ re_replace .Keywords "[^a-z]" "" }}.mirror.test/)

    test "a query holding a secret's windows-1251 bytes is not sent off the credential hosts" do
      assert {{:failed, :secret_host}, []} = secret_search!(@mirror, "frieren " <> @passkey)
    end

    test "the same query without the secret is sent to the keywords' host" do
      assert {outcome, [{"frieren.mirror.test", "/", %{"q" => "frieren"}}]} =
               secret_search!(@mirror, "frieren")

      refute match?({:failed, _}, outcome)
    end

    test "the secret's windows-1251 bytes pass the check on a credential host" do
      # Req.Test refuses a query that is not UTF-8 before its stub runs, so the request that
      # passed the check ends as a transport failure, not as :secret_host.
      assert {outcome, []} =
               secret_search!("https://nyaa.test/", "frieren " <> @passkey)

      assert outcome == {:failed, :connection_failed}
    end

    test "the same credential host answers a query of ASCII keywords" do
      assert {:asked, [{"nyaa.test", "/", %{"q" => "frieren"}}]} =
               secret_search!("https://nyaa.test/", "frieren")
    end
  end
end
