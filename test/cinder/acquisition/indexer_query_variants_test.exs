defmodule Cinder.Acquisition.IndexerQueryVariantsTest do
  # Every `Cinder.Acquisition.Indexer.query` variant through every adapter of the
  # `:indexer_adapters` map (#1632). `Newznab.requests/2` has no catch-all, so a variant with no
  # clause raises, and Native reads that as a crashed indexer and starts a backoff. Each adapter's
  # `search/3` is called here directly, so a raise fails the test, and its outcome must be one a
  # healthy indexer gives.
  #
  # Not async: Native's clock and adapter map are global config.
  use Cinder.DataCase, async: false

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.ConfigCase

  @now ~U[2026-11-26 12:00:00Z]

  # One call per variant, keyed by the variant's tag.
  @variants %{
    search: {:search, "tt0133093"},
    search_movie: {:search_movie, "tt0133093", "The Matrix 1999", []},
    search_movie_query: {:search_movie_query, "The Matrix 1999", []},
    search_tv_query: {:search_tv_query, "Show", []},
    search_tv: {:search_tv, 81_189, "Show", 1},
    search_ebook: {:search_ebook, "Author", "Title", []},
    search_ebook_query: {:search_ebook_query, "Title", []},
    search_audiobook: {:search_audiobook, "Author", "Title", []},
    search_audiobook_query: {:search_audiobook_query, "Title", []}
  }

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp context, do: %{deadline_at: System.monotonic_time(:millisecond) + 90_000}

  # The tags of `Indexer.query`'s variants, read from the compiled type. A variant that is not a
  # tuple led by an atom fails the match, naming the form this read does not know.
  defp query_tags do
    {:ok, types} = Code.Typespec.fetch_types(Indexer)

    {:type, {:query, {:type, _, :union, variants}, []}} =
      Enum.find(types, &match?({:type, {:query, _, _}}, &1))

    Enum.map(variants, fn {:type, _, :tuple, [{:atom, _, tag} | _]} -> tag end)
  end

  test "the variant list names every variant of Indexer.query" do
    assert Enum.sort(query_tags()) == Enum.sort(Map.keys(@variants))
  end

  test "the adapter map holds the three adapters this file runs" do
    assert Map.keys(Application.fetch_env!(:cinder, :indexer_adapters)) |> Enum.sort() ==
             [:cardigann, :newznab, :torznab]
  end

  for type <- [:newznab, :torznab], {tag, query} <- @variants do
    @type_name type
    @query query

    test "#{type} asks every variant: #{tag}" do
      indexer = Cinder.NewznabFixtures.indexer!(@type_name, "a.example")
      Cinder.NewznabFixtures.route(%{"a.example" => fn _conn, _query -> :default end})
      adapter = Map.fetch!(Application.fetch_env!(:cinder, :indexer_adapters), @type_name)

      assert {[], :asked} = adapter.search(indexer, @query, context())
    end
  end

  test "cardigann plans every variant, asking those its modes and categories take" do
    [indexer] =
      Cinder.CardigannFixtures.setup!(
        [{"nyaa.yml", Cinder.CardigannFixtures.nyaa_like(&with_ids/1)}],
        [{"nyaa.yml", Cinder.CardigannFixtures.nyaa_base(), %{}}]
      )

    Cinder.CardigannFixtures.route(%{
      "nyaa.test" => fn _conn, _query -> Cinder.CardigannFixtures.nyaa_page([]) end
    })

    adapter = Map.fetch!(Application.fetch_env!(:cinder, :indexer_adapters), :cardigann)

    outcomes =
      Map.new(@variants, fn {tag, query} ->
        {_rows, outcome} = adapter.search(indexer, query, context())
        {tag, outcome}
      end)

    # The Nyaa-shaped definition maps no Books category, and Audio (3000) is the parent of the
    # audiobook default 3030, not a child, so neither book kind reaches a mapping.
    not_asked = [:search_ebook, :search_ebook_query, :search_audiobook, :search_audiobook_query]

    assert outcomes ==
             Map.new(@variants, fn {tag, _query} ->
               {tag, if(tag in not_asked, do: {:not_asked, :caps}, else: :asked)}
             end)
  end

  # Nyaa-shaped, with `imdbid` under movie-search and book-search taking title and author.
  defp with_ids(definition) do
    definition
    |> put_in(["caps", "modes", "movie-search"], ["q", "imdbid"])
    |> put_in(["caps", "modes", "book-search"], ["q", "title", "author"])
  end
end
