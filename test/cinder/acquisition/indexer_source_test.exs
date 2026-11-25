defmodule Cinder.Acquisition.IndexerSourceTest do
  # Sets PROWLARR_URL, an OS env var every process reads, to read config/runtime.exs.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.{IndexerMock, IndexerSource, InHandIndexerMock}

  # The names this seam had before #1643, built so no source line spells them.
  @old_behaviour Module.concat([Cinder.Acquisition, Indexer])
  @old_prowlarr Module.concat([Cinder.Acquisition, Indexer, Prowlarr])

  @callbacks [
    health: 0,
    search: 1,
    search_audiobook: 3,
    search_audiobook_query: 2,
    search_ebook: 3,
    search_ebook_query: 2,
    search_movie_query: 2,
    search_tv: 3,
    search_tv_query: 2
  ]

  test "the seam and its Prowlarr adapter load under the IndexerSource names only" do
    assert Code.ensure_loaded?(IndexerSource)
    assert Code.ensure_loaded?(IndexerSource.Prowlarr)
    refute Code.ensure_loaded?(@old_behaviour)
    refute Code.ensure_loaded?(@old_prowlarr)
  end

  test "the seam keeps its nine callbacks, and the adapter and both mocks implement it" do
    assert Enum.sort(IndexerSource.behaviour_info(:callbacks)) == @callbacks

    assert IndexerSource in behaviours(IndexerSource.Prowlarr)
    assert IndexerMock.__mock_for__() == [IndexerSource]
    assert InHandIndexerMock.__mock_for__() == [IndexerSource]
  end

  test "the test env names the mock under :indexer_source and sets no :indexer key" do
    assert Application.fetch_env(:cinder, :indexer_source) == {:ok, IndexerMock}

    assert Application.fetch_env(:cinder, :indexer) == :error
  end

  test "config/config.exs selects the Prowlarr adapter under :indexer_source for prod" do
    cinder = Config.Reader.read!("config/config.exs", env: :prod, target: :host)[:cinder]

    assert cinder[:indexer_source] == IndexerSource.Prowlarr
    refute Keyword.has_key?(cinder, :indexer)
  end

  test "config/runtime.exs keys PROWLARR_URL and PROWLARR_API_KEY by the adapter's name" do
    prior = Map.new(~w(PROWLARR_URL PROWLARR_API_KEY), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(prior, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("PROWLARR_URL", "http://prowlarr.example:9696")
    System.put_env("PROWLARR_API_KEY", "runtime-key")

    cinder = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)[:cinder]

    assert cinder[IndexerSource.Prowlarr] ==
             [base_url: "http://prowlarr.example:9696", api_key: "runtime-key"]

    refute Keyword.has_key?(cinder, @old_prowlarr)
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
