defmodule Cinder.IndexersThroughProwlarrTest do
  # The rule for a configured indexer searched through Prowlarr (#1661): a Newznab or Torznab
  # indexer whose API path is `/<digits>/api` and whose base URL, trailing slash removed, equals
  # the saved Prowlarr URL, trailing slash removed.
  #
  # Not async: the Prowlarr base URL is app-wide config, which other test modules read.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @prowlarr "https://media.example.com/prowlarr"

  test "answers each row of the rule" do
    rows = [
      {"https://media.example.com/prowlarr/", "/12/api", @prowlarr, true},
      {"https://media.example.com/prowlarr", "/12/api", @prowlarr, true},
      {"https://media.example.com/prowlarr", "/7/api", @prowlarr <> "/", true},
      {"https://media.example.com/prowlarr/", "/api", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "/12/api/x", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "/12/api\n", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "/x/api", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "12/api", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "/12/api/", @prowlarr, false},
      {"https://other.example.com/prowlarr/", "/12/api", @prowlarr, false},
      {"https://media.example.com/prowlarr/", "/12/api", nil, false},
      {"https://media.example.com/prowlarr/", "/12/api", "", false},
      {"", "/12/api", "", false},
      {"   ", "/12/api", "   ", false},
      {"/", "/12/api", "/", false},
      {" /", "/12/api", " /", false},
      {nil, "/12/api", @prowlarr, false},
      {"https://media.example.com/prowlarr/", nil, @prowlarr, false}
    ]

    for {base_url, api_path, prowlarr_url, expected} <- rows,
        cell =
          {base_url, api_path, prowlarr_url,
           Indexers.through_prowlarr?(base_url, api_path, prowlarr_url)},
        cell != {base_url, api_path, prowlarr_url, expected} do
      flunk("through_prowlarr?/3 answered #{inspect(cell)}, expected #{inspect(expected)}")
    end
  end

  describe "Prowlarr.saved_base_url/0" do
    test "is the configured base URL, and nil for none or a blank one" do
      ConfigCase.put_config(Prowlarr, base_url: @prowlarr)
      assert Prowlarr.saved_base_url() == @prowlarr

      ConfigCase.put_config(Prowlarr, base_url: nil)
      assert Prowlarr.saved_base_url() == nil

      ConfigCase.put_config(Prowlarr, base_url: " ")
      assert Prowlarr.saved_base_url() == nil
    end
  end
end
