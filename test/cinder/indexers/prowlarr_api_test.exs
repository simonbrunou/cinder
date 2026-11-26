defmodule Cinder.Indexers.ProwlarrApiTest do
  # Changes the Prowlarr source's config, which other modules read.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.ConfigCase
  alias Cinder.Indexers.ProwlarrApi
  alias Cinder.Indexers.ProwlarrApi.Connection

  setup :verify_on_exit!

  describe "connection/0" do
    test "the stored URL and key, the URL's base path kept" do
      ConfigCase.put_config(Prowlarr,
        base_url: "https://media.example.com/prowlarr",
        api_key: "stored-key"
      )

      assert {:ok, %Connection{url: "https://media.example.com/prowlarr", api_key: "stored-key"}} =
               ProwlarrApi.connection()
    end

    for {name, overrides} <- [
          {"no URL", [base_url: nil]},
          {"a blank URL", [base_url: "  "]},
          {"no key", [api_key: nil]},
          {"a blank key", [api_key: " "]}
        ] do
      @overrides overrides

      test "#{name} is :not_configured, never the search's localhost default" do
        ConfigCase.put_config(
          Prowlarr,
          Keyword.merge([base_url: "https://p.example", api_key: "k"], @overrides)
        )

        assert {:error, :not_configured} = ProwlarrApi.connection()
      end
    end

    test "a config with neither key set is :not_configured" do
      ConfigCase.put_env(
        Prowlarr,
        :cinder |> Application.get_env(Prowlarr) |> Keyword.drop([:base_url, :api_key])
      )

      assert {:error, :not_configured} = ProwlarrApi.connection()
    end
  end

  test "get/3 calls the adapter the :prowlarr_api key names" do
    ConfigCase.put_env(:prowlarr_api, Cinder.Indexers.OtherProwlarrApiMock)
    connection = %Connection{url: "https://p.example", api_key: "k"}
    stub(Cinder.Indexers.ProwlarrApiMock, :get, fn _c, _path, _query -> {:error, :transport} end)

    expect(Cinder.Indexers.OtherProwlarrApiMock, :get, fn ^connection, "/api/v1/indexer", [] ->
      {:ok, []}
    end)

    assert {:ok, []} = ProwlarrApi.get(connection, "/api/v1/indexer")
  end
end
