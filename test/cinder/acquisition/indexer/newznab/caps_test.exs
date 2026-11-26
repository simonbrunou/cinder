defmodule Cinder.Acquisition.Indexer.Newznab.CapsTest do
  # The `t=caps` parser and the two questions the request planner asks of its result (#1652).
  # A caps answer decides which searches an indexer is asked, so a name the parser reads that
  # comes back renamed fails the whole answer rather than leaving the indexer out (testing.md).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Newznab.Caps

  @modes %{
    "search" => ~s(available="yes" supportedParams="q"),
    "tv-search" => ~s(available="yes" supportedParams="q,season,ep,tvdbid"),
    "movie-search" => ~s(available="yes" supportedParams="q,imdbid"),
    "audio-search" => ~s(available="no" supportedParams="q"),
    "book-search" => ~s(available="yes" supportedParams="q,title,author")
  }

  @categories """
  <category id="2000" name="Movies"><subcat id="2040" name="Movies/HD"/></category>
  <category id="5000" name="TV"><subcat id="5070" name="TV/Anime"/></category>
  """

  @parsed %{
    "modes" => %{
      "search" => ["q"],
      "tv-search" => ["q", "season", "ep", "tvdbid"],
      "movie-search" => ["q", "imdbid"],
      "book-search" => ["q", "title", "author"]
    },
    "categories" => [2000, 2040, 5000, 5070],
    "limits" => %{"max" => 100, "default" => 50}
  }

  # A caps body: `modes` maps a mode to its attributes, a nil value leaves the mode out.
  defp caps(opts \\ []) do
    modes = Keyword.get(opts, :modes, @modes)
    categories = Keyword.get(opts, :categories, @categories)
    limits = Keyword.get(opts, :limits, ~s(<limits max="100" default="50"/>))

    mode_lines = for {name, attrs} <- Enum.sort(modes), attrs, do: "<#{name} #{attrs}/>"

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <server title="Indexer"/>
      #{limits}
      <searching>#{Enum.join(mode_lines)}</searching>
      <categories>#{categories}</categories>
    </caps>
    """
  end

  describe "parse/1" do
    test "reads each available mode's parameters, the category ids and the limits" do
      assert Caps.parse(caps()) == {:ok, @parsed}
    end

    test "reads parameters trimmed and lowercased, each once" do
      body =
        caps(
          modes: %{
            @modes
            | "tv-search" => ~s(available="yes" supportedParams=" Q, Season ,TVDBID,q,")
          }
        )

      assert {:ok, %{"modes" => %{"tv-search" => ["q", "season", "tvdbid"]}}} = Caps.parse(body)
    end

    test "a mode with no supportedParams lists q, as Prowlarr reads it" do
      body = caps(modes: %{@modes | "book-search" => ~s(available="yes")})
      assert {:ok, %{"modes" => %{"book-search" => ["q"]}}} = Caps.parse(body)
    end

    test "a mode that is missing or not available lists nothing" do
      for attrs <- [nil, ~s(available="no" supportedParams="q,imdbid"), ~s(available="yes!")] do
        assert {:ok, %{"modes" => modes}} =
                 Caps.parse(caps(modes: %{@modes | "movie-search" => attrs}))

        assert Map.keys(modes) == ["book-search", "search", "tv-search"], inspect(attrs)
      end
    end

    test "available reads yes in any case" do
      for available <- ["YES", "Yes"] do
        body =
          caps(
            modes: %{
              @modes
              | "movie-search" => ~s(available="#{available}" supportedParams="imdbid")
            }
          )

        assert {:ok, %{"modes" => %{"movie-search" => ["imdbid"]}}} = Caps.parse(body)
      end
    end

    test "music-search, and a searchEngine attribute, as Prowlarr's own caps list them, are left out" do
      body =
        caps(
          modes:
            @modes
            |> Map.put("music-search", ~s(available="yes" supportedParams="q,artist"))
            |> Map.put("search", ~s(available="yes" supportedParams="q" searchEngine="raw"))
        )

      assert Caps.parse(body) == {:ok, @parsed}
    end

    test "music-search is checked for its attributes' names alone" do
      for attrs <- [~s(supportedParams="q"), ~s(available="maybe")] do
        body = caps(modes: Map.put(@modes, "music-search", attrs))
        assert Caps.parse(body) == {:ok, @parsed}, attrs
      end

      body = caps(modes: Map.put(@modes, "music-search", ~s(available="yes" supportedparams="q")))
      assert Caps.parse(body) == {:error, :bad_response}
    end

    test "a mode beside the known ones that none of them names fails the whole answer" do
      body = caps(modes: Map.put(@modes, "xxx-search", ~s(available="yes")))
      assert Caps.parse(body) == {:error, :bad_response}
    end

    test "the limits are nil when absent" do
      assert {:ok, %{"limits" => %{"max" => nil, "default" => nil}}} =
               Caps.parse(caps(limits: ""))

      assert {:ok, %{"limits" => %{"max" => 100, "default" => nil}}} =
               Caps.parse(caps(limits: ~s(<limits max="100"/>)))
    end

    test "a plain caps body beside one with a document type declaration" do
      assert {:ok, _caps} = Caps.parse(caps())

      for declaration <- [
            "<!DOCTYPE caps>",
            ~s(<!DOCTYPE caps [<!ENTITY boom "boom">]>),
            ~s(<!DOCTYPE caps [<!ENTITY ext SYSTEM "file:///etc/passwd">]>)
          ] do
        body = String.replace(caps(), "<caps>", declaration <> "<caps>", global: false)
        assert Caps.parse(body) == {:error, :bad_response}, declaration
      end
    end

    for {name, body} <- [
          {"an <error> answer",
           ~s(<?xml version="1.0"?><error code="100" description="Incorrect user credentials"/>)},
          {"an HTML page", "<html><body><p>Login</p></body></html>"},
          {"a body that is not XML", "Service Unavailable"},
          {"a renamed root", "<capabilities><searching/><categories/></capabilities>"}
        ] do
      @body body
      test "#{name} reads as a bad response" do
        assert Caps.parse(@body) == {:error, :bad_response}
      end
    end

    test "a decoded JSON body reads as a bad response" do
      assert Caps.parse(%{"caps" => []}) == {:error, :bad_response}
    end

    for {name, from, to} <- [
          {"searching", "searching>", "searchin>"},
          {"categories", "categories>", "categorys>"},
          {"available", ~s(<movie-search available=), ~s(<movie-search availble=)}
        ] do
      @from from
      @to to

      test "a renamed #{name} element or attribute fails the whole answer" do
        renamed = String.replace(caps(), @from, @to)
        assert renamed != caps()
        assert Caps.parse(renamed) == {:error, :bad_response}
      end
    end

    # Each mode name and `supportedParams`, renamed in a `searching` holding that mode alone and
    # in one holding it beside the other modes; the valid form of each body is the control.
    for mode <- ~w(search tv-search movie-search audio-search book-search),
        {name, from, to} <- [
          {"element", "<#{mode} ", "<#{String.replace(mode, "search", "serch")} "},
          {"supportedParams", "<#{mode} available=\"yes\" supportedParams=",
           "<#{mode} available=\"yes\" supportedparams="}
        ] do
      @mode mode
      @from from
      @to to

      test "a renamed #{mode} #{name} fails the whole answer, alone or beside the other modes" do
        alone = %{@mode => ~s(available="yes" supportedParams="q")}
        beside = Map.put(@modes, @mode, ~s(available="yes" supportedParams="q"))

        for modes <- [alone, beside] do
          valid = caps(modes: modes)
          renamed = String.replace(valid, @from, @to)

          assert renamed != valid
          assert {:ok, %{"modes" => %{@mode => ["q"]}}} = Caps.parse(valid)
          assert Caps.parse(renamed) == {:error, :bad_response}, renamed
        end
      end
    end

    # Each name read under `categories`, renamed in an entry alone and in one beside valid
    # entries; the valid form of each body is the control.
    for {name, valid, renamed} <- [
          {"category", ~s(<category id="5000"/>), ~s(<categoy id="5000"/>)},
          {"a category's id", ~s(<category id="5000"/>), ~s(<category ID="5000"/>)},
          {"subcat", ~s(<category id="5000"><subcat id="5070"/></category>),
           ~s(<category id="5000"><subcatt id="5070"/></category>)},
          {"a subcat's id", ~s(<category id="5000"><subcat id="5070"/></category>),
           ~s(<category id="5000"><subcat i="5070"/></category>)}
        ] do
      @valid valid
      @renamed renamed

      test "a renamed #{name} fails the whole answer, alone or beside valid entries" do
        beside = ~s(<category id="2000"><subcat id="2040"/></category>)

        assert {:ok, %{"categories" => [_ | _]}} = Caps.parse(caps(categories: @valid))
        assert {:ok, %{"categories" => [_ | _]}} = Caps.parse(caps(categories: beside <> @valid))
        assert Caps.parse(caps(categories: @renamed)) == {:error, :bad_response}
        assert Caps.parse(caps(categories: beside <> @renamed)) == {:error, :bad_response}
      end
    end

    test "an id or a limit that is not a non-negative integer fails the answer" do
      for bad <- ["", "x", "-1", "1.5", "20 00", "２０００"] do
        for body <- [
              caps(categories: ~s(<category id="#{bad}"/>)),
              caps(categories: ~s(<category id="5000"><subcat id="#{bad}"/></category>)),
              caps(limits: ~s(<limits max="#{bad}"/>)),
              caps(limits: ~s(<limits default="#{bad}"/>))
            ] do
          assert Caps.parse(body) == {:error, :bad_response}, body
        end
      end
    end

    test "raises on no odd value in any slot it reads" do
      values = [
        "",
        " ",
        "yes ",
        "q,,",
        "-1",
        "1e3",
        <<0xFF>>,
        "&amp;",
        String.duplicate("9", 400),
        # Past the BEAM's integer limit, where `Integer.parse/1` raises (#1653 review).
        String.duplicate("9", 2_000_000)
      ]

      mode_slots =
        for mode <- Map.keys(@modes) do
          [
            &caps(modes: %{@modes | mode => ~s(available="#{&1}" supportedParams="q")}),
            &caps(modes: %{@modes | mode => ~s(available="yes" supportedParams="#{&1}")})
          ]
        end

      slots =
        List.flatten(mode_slots) ++
          [
            &caps(categories: ~s(<category id="#{&1}"/>)),
            &caps(categories: ~s(<category id="1"><subcat id="#{&1}"/></category>)),
            &caps(categories: ~s(<category id="1">#{&1}</category>)),
            &caps(categories: &1),
            &caps(limits: ~s(<limits max="#{&1}" default="#{&1}"/>)),
            &caps(limits: &1)
          ]

      for slot <- slots, value <- values do
        assert match?({:ok, %{}}, Caps.parse(slot.(value))) or
                 Caps.parse(slot.(value)) == {:error, :bad_response}
      end
    end
  end

  describe "param?/3" do
    test "answers whether a mode lists a parameter" do
      {:ok, caps} = Caps.parse(caps())

      assert Caps.param?(caps, "movie-search", "imdbid")
      refute Caps.param?(caps, "tv-search", "imdbid")
      refute Caps.param?(caps, "audio-search", "q")
    end
  end

  describe "categories/2" do
    # `{scope, listed ids, expected}`, each cell compared whole.
    @cases [
      {[2000], [2000, 2040, 5000], [2000, 2040]},
      {[2000], [2040], [2040]},
      {[2040], [2000, 2040], [2040]},
      {[2040], [2000, 2030], []},
      {[5070], [5000], []},
      {[2000, 5070], [2040, 5000, 5070], [2040, 5070]},
      {[0], [10, 20, 500], [10, 20]},
      {[9000], [9000, 9500], [9000]},
      {[100_000], [100_001], []},
      {[], [2000], []}
    ]

    test "picks the listed ids the scope takes in" do
      for {scope, listed, expected} <- @cases,
          cell = {scope, listed, Caps.categories(%{"categories" => listed}, scope)},
          cell != {scope, listed, expected} do
        flunk("categories #{inspect(cell, charlists: :as_lists)}, expected #{inspect(expected)}")
      end
    end
  end

  describe "covers?/2" do
    # `{scope, listed ids, expected}`; the whole cell is compared, so a false row is checked too.
    @cases [
      {[2000], [2000], true},
      {[2000], [2040], true},
      {[2040], [2000, 2040], true},
      {[2040], [2000, 2030], false},
      {[5070], [5000], false},
      {[5070], [5000, 5070], true},
      {[2000], [5000, 5070], false},
      {[0], [10], true},
      {[0], [20], true},
      {[0], [500], false},
      {[1000], [1500], true},
      {[8000], [8010], true},
      {[9000], [9500], false},
      {[9000], [9000], true},
      {[100_001], [100_001], true},
      {[100_000], [100_001], false},
      {[5000], [], false},
      {[2000, 5070], [5070], true},
      {[], [2000], false}
    ]

    test "matches a scope through the category tree" do
      for {scope, listed, expected} <- @cases,
          cell = {scope, listed, Caps.covers?(%{"categories" => listed}, scope)},
          cell != {scope, listed, expected} do
        flunk("covers? #{inspect(cell)}, expected #{expected}")
      end
    end
  end
end
